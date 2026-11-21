extends "res://match_role.gd"

# ==============================================================================
# TAKTİKSEL YAPAY ZEKA MOTORU (HÜCUM & SAVUNMA VARYASYONLARI)
# ==============================================================================

enum TacticalRole {
	CENTER_BACK,
	FULLBACK,
	DEFENSIVE_MID,
	CENTRAL_MID,
	WINGER,
	STRIKER
}

enum AttackPhase {
	BUILD_UP,        # 1. Bölge: Geriden oyun kurma ve baskı kırma
	TRANSITION,      # Geçiş: Top kazanıldığı an dikine kontra atak
	PROGRESSION,     # 2. Bölge: Orta saha bloklarını aşma ve kanat yüklemesi
	FINAL_THIRD,     # 3. Bölge: Kapalı savunma açma, half-space ve verkaçlar
	CROSS_SITUATION  # Son Çizgi: Ceza sahası içi 5 bölgeli gol paylaşımı
}

enum RunAction {
	NONE,
	STRETCH_WIDE,     # Çizgiye basıp oyunu genişletme
	HALF_SPACE_DIVE,  # Bek-stoper arasına çapraz koşu
	DROP_TO_LINK,     # Top almaya yaklaşma (False 9 / Pivot / Regista)
	OVERLAP_RUN,      # Top taşıyanın dışından bindirme
	UNDERLAP_RUN,     # Top taşıyanın içinden bindirme
	NEAR_POST_RUN,    # Ön direk koşusu
	FAR_POST_RUN,     # Arka direk koşusu
	CUTBACK_ZONE,     # Penaltı noktası / yay gerisi yerden pas bekleme
	REBOUND_EDGE,     # Ceza sahası yayı dışı seken top kontrolü
	SWITCH_OUTLET     # Ters kanatta tamamen boş alan bekleme (Isolate)
}

# Oyuncu bazlı koşu hafızası -> { player_id: { "action": RunAction, "expire_ms": int, "phase": AttackPhase } }
var _run_memory: Dictionary = {}

const RUN_LOCK_DURATION_MS: int = 1650
const MIN_TEAMMATE_SPACING: float = 4.8
const PASS_LANE_CLEARANCE: float = 2.4


# ==============================================================================
# ANA GİRİŞ NOKTASI 1: HÜCUM VE DESTEK POZİSYONU
# ==============================================================================
func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var ctx: Dictionary = _build_attack_context(player, carrier, attack_sign)
	var phase: AttackPhase = _determine_attack_phase(ctx)
	var role: TacticalRole = ctx.role
	
	# Mevcut faz ve role göre en uygun koşu aksiyonunu seç veya hafızadan koru
	var action: RunAction = _resolve_player_run_action(ctx, phase)
	var raw_target: Vector3 = _compute_target_for_action(ctx, phase, action)
	
	# 1. Pas açısı kapalıysa (rakip pas çizgisindeyse) oyuncuyu boşa çıkar
	if role != TacticalRole.CENTER_BACK and phase != AttackPhase.CROSS_SITUATION:
		raw_target = _adjust_for_pass_lane_visibility(ctx, raw_target)
	
	# 2. Takım arkadaşlarıyla üst üste binmeyi (Clumping) engelle
	raw_target = _apply_teammate_spacing(player, raw_target, ctx)
	
	# 3. Diziliş pozisyonu ile taktiksel hedefi faza uygun ağırlıkla harmanla
	var weight: float = _get_phase_blend_weight(phase, role)
	var blended: Vector3 = ctx.form_pos.lerp(raw_target, weight)
	
	# 4. Saha içi sınırlar ve mutlak ofsayt kilidini uygula
	return _clamp_to_pitch_and_offside(blended, ctx)


# ==============================================================================
# BAĞLAM OLUŞTURMA VE ROL TESPİTİ
# ==============================================================================
func _build_attack_context(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Dictionary:
	var ball_pos: Vector3 = controller.ball.global_position
	var ball_vel: Vector3 = controller.ball.linear_velocity
	var carrier_pos: Vector3 = carrier.global_position if is_instance_valid(carrier) else ball_pos
	var enemy_goal_z: float = attack_sign * FIELD_HALF_LENGTH
	var own_goal_z: float = -attack_sign * FIELD_HALF_LENGTH
	
	# Ofsayt sınırı hesaplaması
	var raw_offside_limit: float = maxf(0.0, controller._offside_line_progress(player.team) - 1.25)
	var ball_progress: float = maxf(0.0, ball_pos.z * attack_sign)
	var safe_max_z_progress: float = maxf(raw_offside_limit, ball_progress - 0.5)
	
	# Topun sahadaki ilerleme oranı (0.0 = Kendi kalemiz, 1.0 = Rakip kale)
	var total_length: float = FIELD_HALF_LENGTH * 2.0
	var ball_prog_ratio: float = clampf(((ball_pos.z * attack_sign) + FIELD_HALF_LENGTH) / total_length, 0.0, 1.0)
	
	var role: TacticalRole = _infer_tactical_role(player, attack_sign)
	var flank_overload: float = _calculate_flank_overload(player.team, ball_pos)
	
	return {
		"player": player,
		"player_id": player.get_instance_id(),
		"carrier": carrier,
		"attack_sign": attack_sign,
		"form_pos": formation_position(player, attack_sign, true),
		"ball_pos": ball_pos,
		"ball_vel": ball_vel,
		"carrier_pos": carrier_pos,
		"enemy_goal_z": enemy_goal_z,
		"own_goal_z": own_goal_z,
		"dist_ball_to_goal": absf(enemy_goal_z - ball_pos.z),
		"ball_prog_ratio": ball_prog_ratio,
		"safe_max_z_progress": safe_max_z_progress,
		"spawn_x": player.spawn_position.x,
		"spawn_z_signed": player.spawn_position.z * attack_sign,
		"slot": maxi(player.field_slot, 0),
		"role": role,
		"flank_overload": flank_overload,
		"half_width": controller.FIELD_HALF_WIDTH
	}

func _infer_tactical_role(player: CharacterBody3D, attack_sign: float) -> TacticalRole:
	var sx: float = absf(player.spawn_position.x)
	var sz: float = player.spawn_position.z * attack_sign
	var is_wide: bool = sx > 9.2
	
	# Diziliş derinliğine (Z) ve genişliğine (X) göre 6 modern rol ataması
	if sz < -16.0:
		return TacticalRole.FULLBACK if is_wide else TacticalRole.CENTER_BACK
	elif sz < -2.0:
		return TacticalRole.WINGER if is_wide else TacticalRole.DEFENSIVE_MID
	elif sz < 12.0:
		return TacticalRole.WINGER if is_wide else TacticalRole.CENTRAL_MID
	else:
		return TacticalRole.WINGER if is_wide else TacticalRole.STRIKER

func _determine_attack_phase(ctx: Dictionary) -> AttackPhase:
	var prog: float = ctx.ball_prog_ratio
	var ball_vel_forward: float = ctx.ball_vel.z * ctx.attack_sign
	var is_wide: bool = absf(ctx.ball_pos.x) > (ctx.half_width * 0.60)
	
	# Top orta sahada hızla rakip kaleye doğru hareket ediyorsa Geçiş Hücumu (Kontra)
	if prog > 0.30 and prog < 0.76 and ball_vel_forward > 7.5:
		return AttackPhase.TRANSITION
		
	if prog < 0.34:
		return AttackPhase.BUILD_UP
	elif prog < 0.68:
		return AttackPhase.PROGRESSION
	else:
		if is_wide and ctx.dist_ball_to_goal < 23.5:
			return AttackPhase.CROSS_SITUATION
		return AttackPhase.FINAL_THIRD


# ==============================================================================
# KOŞU KARAR MEKANİZMASI VE HAFIZA KİLİDİ
# ==============================================================================
func _resolve_player_run_action(ctx: Dictionary, phase: AttackPhase) -> RunAction:
	var pid: int = ctx.player_id
	var now: int = Time.get_ticks_msec()
	
	# Ceza sahası ortası gibi acil durumlarda kilidi beklemeden tepki ver
	var urgent_phase: bool = (phase == AttackPhase.CROSS_SITUATION or phase == AttackPhase.TRANSITION)
	
	if not urgent_phase and _run_memory.has(pid):
		var mem: Dictionary = _run_memory[pid]
		if now < mem.expire_ms and mem.phase == phase:
			return mem.action
			
	var chosen: RunAction = _select_best_action_for_role(ctx, phase)
	_run_memory[pid] = {
		"action": chosen,
		"phase": phase,
		"expire_ms": now + RUN_LOCK_DURATION_MS
	}
	return chosen

func _select_best_action_for_role(ctx: Dictionary, phase: AttackPhase) -> RunAction:
	var role: TacticalRole = ctx.role
	var same_flank: bool = signf(ctx.spawn_x) == signf(ctx.ball_pos.x) and absf(ctx.ball_pos.x) > 3.5
	var slot: int = ctx.slot
	
	match phase:
		AttackPhase.BUILD_UP:
			match role:
				TacticalRole.CENTER_BACK:
					return RunAction.STRETCH_WIDE
				TacticalRole.FULLBACK:
					return RunAction.STRETCH_WIDE if same_flank else RunAction.SWITCH_OUTLET
				TacticalRole.DEFENSIVE_MID:
					return RunAction.DROP_TO_LINK
				TacticalRole.CENTRAL_MID:
					return RunAction.DROP_TO_LINK if slot % 2 == 0 else RunAction.HALF_SPACE_DIVE
				TacticalRole.WINGER:
					return RunAction.STRETCH_WIDE
				TacticalRole.STRIKER:
					return RunAction.DROP_TO_LINK if ctx.dist_ball_to_goal > 65.0 else RunAction.STRETCH_WIDE
					
		AttackPhase.TRANSITION:
			match role:
				TacticalRole.STRIKER, TacticalRole.WINGER:
					return RunAction.HALF_SPACE_DIVE
				TacticalRole.CENTRAL_MID:
					return RunAction.UNDERLAP_RUN
				TacticalRole.FULLBACK:
					return RunAction.OVERLAP_RUN if same_flank else RunAction.SWITCH_OUTLET
				_:
					return RunAction.NONE
					
		AttackPhase.PROGRESSION:
			# Eğer topun olduğu kanatta aşırı yığılma varsa ters kanada oyun açma opsiyonu yarat
			var overloaded_on_ball: bool = absf(ctx.flank_overload) >= 2.0 and signf(ctx.flank_overload) == signf(ctx.ball_pos.x)
			
			match role:
				TacticalRole.FULLBACK:
					if same_flank:
						return RunAction.OVERLAP_RUN if slot % 2 == 0 else RunAction.UNDERLAP_RUN
					return RunAction.SWITCH_OUTLET
				TacticalRole.DEFENSIVE_MID:
					return RunAction.DROP_TO_LINK
				TacticalRole.CENTRAL_MID:
					if same_flank:
						return RunAction.UNDERLAP_RUN
					return RunAction.HALF_SPACE_DIVE
				TacticalRole.WINGER:
					if same_flank:
						return RunAction.STRETCH_WIDE
					return RunAction.SWITCH_OUTLET if overloaded_on_ball else RunAction.HALF_SPACE_DIVE
				TacticalRole.STRIKER:
					var carrier_far: bool = absf(ctx.carrier_pos.z - (ctx.safe_max_z_progress * ctx.attack_sign)) > 26.0
					return RunAction.DROP_TO_LINK if carrier_far else RunAction.HALF_SPACE_DIVE
				_:
					return RunAction.NONE
					
		AttackPhase.FINAL_THIRD:
			match role:
				TacticalRole.FULLBACK:
					return RunAction.OVERLAP_RUN if same_flank else RunAction.REBOUND_EDGE
				TacticalRole.DEFENSIVE_MID:
					return RunAction.REBOUND_EDGE
				TacticalRole.CENTRAL_MID:
					return RunAction.UNDERLAP_RUN if same_flank else RunAction.CUTBACK_ZONE
				TacticalRole.WINGER:
					return RunAction.STRETCH_WIDE if same_flank else RunAction.HALF_SPACE_DIVE
				TacticalRole.STRIKER:
					return RunAction.NEAR_POST_RUN if slot % 2 == 0 else RunAction.CUTBACK_ZONE
				_:
					return RunAction.NONE
					
		AttackPhase.CROSS_SITUATION:
			match role:
				TacticalRole.WINGER:
					return RunAction.DROP_TO_LINK if same_flank else RunAction.FAR_POST_RUN
				TacticalRole.STRIKER:
					return RunAction.NEAR_POST_RUN if slot % 2 == 0 else RunAction.CUTBACK_ZONE
				TacticalRole.CENTRAL_MID:
					return RunAction.CUTBACK_ZONE if slot % 2 == 1 else RunAction.REBOUND_EDGE
				TacticalRole.FULLBACK:
					return RunAction.DROP_TO_LINK if same_flank else RunAction.REBOUND_EDGE
				TacticalRole.DEFENSIVE_MID:
					return RunAction.REBOUND_EDGE
				_:
					return RunAction.NONE
					
	return RunAction.NONE


# ==============================================================================
# TAKTİKSEL HEDEFLERİN VEKTÖR HESAPLAMALARI (FAZ & AKSİYON BAZLI)
# ==============================================================================
func _compute_target_for_action(ctx: Dictionary, phase: AttackPhase, action: RunAction) -> Vector3:
	match phase:
		AttackPhase.BUILD_UP:
			return _calc_buildup_vectors(ctx, action)
		AttackPhase.TRANSITION:
			return _calc_transition_vectors(ctx, action)
		AttackPhase.PROGRESSION:
			return _calc_progression_vectors(ctx, action)
		AttackPhase.FINAL_THIRD:
			return _calc_final_third_vectors(ctx, action)
		AttackPhase.CROSS_SITUATION:
			return _calc_cross_box_vectors(ctx, action)
	return ctx.form_pos

# --- FAZ 1: GERİDEN OYUN KURMA (BUILD-UP) ---
func _calc_buildup_vectors(ctx: Dictionary, action: RunAction) -> Vector3:
	var pos: Vector3 = ctx.form_pos
	var sign_a: float = ctx.attack_sign
	var half_w: float = ctx.half_width
	
	match ctx.role:
		TacticalRole.CENTER_BACK:
			# Stoperler kaleciden pas almak için ceza sahası köşelerine iyice açılır (Split CBs)
			var side: float = signf(ctx.spawn_x) if absf(ctx.spawn_x) > 0.5 else (1.0 if ctx.slot % 2 == 0 else -1.0)
			pos.x = side * (half_w * 0.48)
			pos.z = ctx.own_goal_z + (sign_a * 11.5)
			
		TacticalRole.FULLBACK:
			# Bekler çizgiye yapışıp derinlik verir
			pos.x = signf(ctx.spawn_x) * (half_w - 2.2)
			pos.z = ctx.carrier_pos.z + (sign_a * 14.0)
			
		TacticalRole.DEFENSIVE_MID:
			# 6 Numara (Regista): İki stoperin arasına veya hemen önüne pas istasyonu olur
			var lateral_offset: float = -signf(ctx.ball_pos.x) * 3.5 if absf(ctx.ball_pos.x) > 4.0 else 0.0
			pos.x = lateral_offset
			pos.z = ctx.carrier_pos.z + (sign_a * 10.5)
			
		TacticalRole.CENTRAL_MID:
			if action == RunAction.DROP_TO_LINK:
				# Rakip forvet arkasına (Pocket) girip dikine pas açısı yaratır
				pos.x = lerpf(ctx.spawn_x, ctx.ball_pos.x * 0.65, 0.55)
				pos.z = ctx.carrier_pos.z + (sign_a * 17.5)
			else:
				pos.x = signf(ctx.spawn_x) * 8.5
				pos.z = ctx.carrier_pos.z + (sign_a * 23.0)
				
		TacticalRole.WINGER:
			# Kanatlar rakip bekleri geri itmek için geniş ve yüksek konumlanır
			pos.x = signf(ctx.spawn_x) * (half_w - 2.0)
			pos.z = ctx.carrier_pos.z + (sign_a * 28.0)
			
		TacticalRole.STRIKER:
			if action == RunAction.DROP_TO_LINK:
				# Uzun top veya duvar pası için orta yuvarlağa yaklaşır
				pos.x = lerpf(ctx.spawn_x * 0.4, ctx.ball_pos.x * 0.4, 0.5)
				pos.z = ctx.carrier_pos.z + (sign_a * 32.0)
			else:
				pos.z = ctx.safe_max_z_progress * sign_a
				
	return pos

# --- FAZ 2: GEÇİŞ HÜCUMU / KONTRA ATAK (TRANSITION) ---
func _calc_transition_vectors(ctx: Dictionary, action: RunAction) -> Vector3:
	var pos: Vector3 = ctx.form_pos
	var sign_a: float = ctx.attack_sign
	var half_w: float = ctx.half_width
	
	match ctx.role:
		TacticalRole.STRIKER:
			# Savunma arkasına çapraz koşu (Diagonal Sprint)
			var run_side: float = -signf(ctx.carrier_pos.x) if absf(ctx.carrier_pos.x) > 3.0 else (1.0 if ctx.slot % 2 == 0 else -1.0)
			pos.x = clampf(ctx.carrier_pos.x + (run_side * 7.5), -11.0, 11.0)
			pos.z = ctx.safe_max_z_progress * sign_a
			
		TacticalRole.WINGER:
			# Maksimum genişlikte savunma arkasına sprint
			pos.x = signf(ctx.spawn_x) * (half_w - 3.2)
			pos.z = ctx.safe_max_z_progress * sign_a
			
		TacticalRole.CENTRAL_MID:
			# İkinci dalga (Trailer) olarak merkez koridordan ceza sahasına sprint
			pos.x = lerpf(ctx.spawn_x, ctx.ball_pos.x * 0.35, 0.5)
			pos.z = minf((ctx.carrier_pos.z + sign_a * 16.0) * sign_a, ctx.safe_max_z_progress) * sign_a
			
		TacticalRole.FULLBACK:
			if action == RunAction.OVERLAP_RUN:
				pos.x = signf(ctx.spawn_x) * (half_w - 2.5)
				pos.z = ctx.carrier_pos.z + (sign_a * 12.0)
			else:
				# Ters bek olası top kaybına karşı merkeze devrilir (Rest Defense)
				pos.x = signf(ctx.spawn_x) * 6.5
				pos.z = ctx.carrier_pos.z - (sign_a * 4.0)
				
		TacticalRole.DEFENSIVE_MID, TacticalRole.CENTER_BACK:
			# Kontra yerken denge savunması (Rest Defense)
			pos.x = lerpf(ctx.spawn_x * 0.75, ctx.ball_pos.x * 0.3, 0.4)
			pos.z = ctx.carrier_pos.z - (sign_a * 12.0)
			
	return pos

# --- FAZ 3: ORTA SAHA İLERLEME VE BLOK KIRMA (PROGRESSION) ---
func _calc_progression_vectors(ctx: Dictionary, action: RunAction) -> Vector3:
	var pos: Vector3 = ctx.form_pos
	var sign_a: float = ctx.attack_sign
	var half_w: float = ctx.half_width
	
	match action:
		RunAction.STRETCH_WIDE:
			pos.x = signf(ctx.spawn_x) * (half_w - 2.0)
			pos.z = ctx.carrier_pos.z + (sign_a * 13.5)
			
		RunAction.SWITCH_OUTLET:
			# Ters kanatta tamamen izole kalarak uzun diyagonal pas bekler
			pos.x = signf(ctx.spawn_x) * (half_w - 1.8)
			pos.z = ctx.carrier_pos.z + (sign_a * 11.0)
			
		RunAction.OVERLAP_RUN:
			# Topu taşıyan kanat oyuncusunun dışından çizgiye bindirme
			pos.x = signf(ctx.spawn_x) * (half_w - 1.8)
			pos.z = ctx.carrier_pos.z + (sign_a * 15.0)
			
		RunAction.UNDERLAP_RUN:
			# Topu taşıyanın iç koridorundan (Half-Space) savunma arkasına sızma
			var side: float = signf(ctx.spawn_x) if absf(ctx.spawn_x) > 1.0 else signf(ctx.ball_pos.x)
			pos.x = side * 7.8
			pos.z = ctx.carrier_pos.z + (sign_a * 14.5)
			
		RunAction.HALF_SPACE_DIVE:
			var side: float = signf(ctx.spawn_x) if absf(ctx.spawn_x) > 1.0 else (1.0 if ctx.slot % 2 == 0 else -1.0)
			pos.x = side * 8.5
			pos.z = minf((ctx.carrier_pos.z + sign_a * 17.0) * sign_a, ctx.safe_max_z_progress) * sign_a
			
		RunAction.DROP_TO_LINK:
			if ctx.role == TacticalRole.STRIKER:
				# Sahte 9 (False 9): Stoperleri üzerine çekip orta sahaya yaklaşır
				pos.x = lerpf(ctx.spawn_x * 0.5, ctx.ball_pos.x, 0.4)
				pos.z = ctx.carrier_pos.z + (sign_a * 14.0)
			else:
				# 6 Numara: Topun gerisinde sigorta pas opsiyonu (Pivot)
				pos.x = lerpf(ctx.spawn_x, ctx.ball_pos.x * 0.55, 0.6)
				pos.z = ctx.carrier_pos.z - (sign_a * 7.5)
				
		_:
			# Stoperler orta çizgiye kadar çıkıp takımı sıkıştırır (High Line)
			if ctx.role == TacticalRole.CENTER_BACK:
				pos.x = lerpf(ctx.spawn_x * 0.85, ctx.ball_pos.x * 0.25, 0.35)
				pos.z = ctx.carrier_pos.z - (sign_a * 18.0)
				
	return pos

# --- FAZ 4: SON BÖLGE / KAPALI SAVUNMA AÇMA (FINAL THIRD) ---
func _calc_final_third_vectors(ctx: Dictionary, action: RunAction) -> Vector3:
	var pos: Vector3 = ctx.form_pos
	var sign_a: float = ctx.attack_sign
	var half_w: float = ctx.half_width
	var goal_z: float = ctx.enemy_goal_z
	
	match action:
		RunAction.STRETCH_WIDE:
			# Kanat oyuncusu çizgiye basarak rakip beki ceza sahasından dışarı çeker
			pos.x = signf(ctx.spawn_x) * (half_w - 2.2)
			pos.z = goal_z - (sign_a * 11.5)
			
		RunAction.OVERLAP_RUN:
			# Bek oyuncusu son çizgiye kadar bindirir
			pos.x = signf(ctx.spawn_x) * (half_w - 2.0)
			pos.z = goal_z - (sign_a * 6.5)
			
		RunAction.UNDERLAP_RUN:
			# 8/10 Numara bek ile stoper arasındaki kanala (Half-space) sızar
			var side: float = signf(ctx.spawn_x) if absf(ctx.spawn_x) > 1.0 else signf(ctx.ball_pos.x)
			pos.x = side * 7.6
			pos.z = goal_z - (sign_a * 9.0)
			
		RunAction.HALF_SPACE_DIVE:
			# Ters kanat içe kat edip gizli forvet olur (Inside Forward)
			pos.x = signf(ctx.spawn_x) * 7.5
			pos.z = goal_z - (sign_a * 8.5)
			
		RunAction.NEAR_POST_RUN:
			# Santrafor stoperin kör noktasına (Blindside) kaçar
			var dodge: float = -signf(ctx.carrier_pos.x) if absf(ctx.carrier_pos.x) > 2.0 else 1.0
			pos.x = clampf(ctx.carrier_pos.x + (dodge * 4.5), -7.0, 7.0)
			pos.z = goal_z - (sign_a * 6.8)
			
		RunAction.CUTBACK_ZONE:
			# Penaltı noktası civarında yerden pas veya verkaç istasyonu
			pos.x = -signf(ctx.ball_pos.x) * 2.2 if absf(ctx.ball_pos.x) > 2.0 else 0.0
			pos.z = goal_z - (sign_a * 11.5)
			
		RunAction.REBOUND_EDGE:
			# Ceza sahası yayında (18-20m) hem şut hem kontra önleme pozisyonu
			var side: float = signf(ctx.spawn_x) if absf(ctx.spawn_x) > 2.0 else -signf(ctx.ball_pos.x)
			pos.x = clampf(side * 6.5, -11.0, 11.0)
			pos.z = goal_z - (sign_a * 19.5)
			
		_:
			if ctx.role == TacticalRole.CENTER_BACK:
				pos.z = goal_z - (sign_a * 36.0)
				pos.x = lerpf(ctx.spawn_x * 0.8, ctx.ball_pos.x * 0.25, 0.3)
				
	return pos

# --- FAZ 5: KANAT ORTASI VE CEZA SAHASI PAYLAŞIMI (CROSS SITUATION) ---
func _calc_cross_box_vectors(ctx: Dictionary, action: RunAction) -> Vector3:
	var pos: Vector3 = ctx.form_pos
	var sign_a: float = ctx.attack_sign
	var goal_z: float = ctx.enemy_goal_z
	var ball_side: float = signf(ctx.ball_pos.x)
	
	match action:
		RunAction.NEAR_POST_RUN:
			# Ön direk koşusu (Kaleci ile stoper arasına sert koşu)
			pos.x = ball_side * 4.2
			pos.z = goal_z - (sign_a * 4.8)
			
		RunAction.FAR_POST_RUN:
			# Ters kanat oyuncusu arka direğe kapanır (Back-post tap-in)
			pos.x = -ball_side * 5.8
			pos.z = goal_z - (sign_a * 5.8)
			
		RunAction.CUTBACK_ZONE:
			# Penaltı noktası hizasında savunmanın geriye çekilmesinden doğan boşluğa yerleşir
			pos.x = -ball_side * 1.6
			pos.z = goal_z - (sign_a * 10.8)
			
		RunAction.DROP_TO_LINK:
			# Topu süren kanat oyuncusuna sıkışırsa geri pas (Cut-back outlet) opsiyonu
			pos.x = ball_side * (ctx.half_width - 4.8)
			pos.z = ctx.carrier_pos.z - (sign_a * 5.2)
			
		RunAction.REBOUND_EDGE:
			# Ceza sahası yayı dışı (Seken toplar ve uzak şut)
			pos.x = -ball_side * 4.5
			pos.z = goal_z - (sign_a * 18.5)
			
		_:
			if ctx.role == TacticalRole.CENTER_BACK:
				pos.z = goal_z - (sign_a * 38.0)
				pos.x = ctx.spawn_x * 0.75
				
	return pos


# ==============================================================================
# İLERİ DÜZEY YARDIMCI SİSTEMLER (PAS GÖLGESİ, YOĞUNLUK, SPACING)
# ==============================================================================

# 1. Pas Çizgisi Görünürlüğü (Pass Lane Visibility): Rakip pas yolunu kapatıyorsa boşa çık
func _adjust_for_pass_lane_visibility(ctx: Dictionary, target: Vector3) -> Vector3:
	if not controller.has_method("get_opponents"):
		return target
		
	var carrier_pos: Vector3 = ctx.carrier_pos
	var pass_vec: Vector3 = target - carrier_pos
	pass_vec.y = 0.0
	var pass_len: float = pass_vec.length()
	
	# Çok kısa veya çok uzun toplarda açı düzeltmesine gerek yok
	if pass_len < 4.5 or pass_len > 32.0:
		return target
		
	var pass_dir: Vector3 = pass_vec / pass_len
	var perp_dir: Vector3 = Vector3(-pass_dir.z, 0.0, pass_dir.x)
	var adjusted: Vector3 = target
	
	for opp in controller.get_opponents(ctx.player.team):
		if not is_instance_valid(opp):
			continue
		var to_opp: Vector3 = opp.global_position - carrier_pos
		to_opp.y = 0.0
		var proj: float = to_opp.dot(pass_dir)
		
		# Rakip pas çizgisinin üzerindeyse
		if proj > 1.5 and proj < pass_len - 1.0:
			var lateral_dist: float = to_opp.dot(perp_dir)
			if absf(lateral_dist) < PASS_LANE_CLEARANCE:
				# Rakibin ters yönüne doğru 2.8 metre kayarak pas açısını temizle
				var dodge_sign: float = -signf(lateral_dist) if absf(lateral_dist) > 0.1 else 1.0
				adjusted += perp_dir * dodge_sign * 2.8
				break
				
	return adjusted

# 2. Kanat Yığılma Analizi (Overload Detection): Hangi kanatta kaç takım arkadaşı var?
func _calculate_flank_overload(team: int, ball_pos: Vector3) -> float:
	if not controller.has_method("get_teammates"):
		return 0.0
		
	var left_count: int = 0
	var right_count: int = 0
	for mate in controller.get_teammates(team):
		if not is_instance_valid(mate):
			continue
		if absf(mate.global_position.z - ball_pos.z) < 18.0:
			if mate.global_position.x < -6.0:
				left_count += 1
			elif mate.global_position.x > 6.0:
				right_count += 1
				
	return float(right_count - left_count)

# 3. Takım Arkadaşı Mesafe Koruma (Anti-Clumping / Spacing)
func _apply_teammate_spacing(player: CharacterBody3D, target: Vector3, ctx: Dictionary) -> Vector3:
	if not controller.has_method("get_teammates"):
		return target
		
	var adjusted: Vector3 = target
	for mate in controller.get_teammates(player.team):
		if not is_instance_valid(mate) or mate == player or mate == ctx.carrier:
			continue
		var diff: Vector3 = adjusted - mate.global_position
		diff.y = 0.0
		var dist: float = diff.length()
		if dist < MIN_TEAMMATE_SPACING and dist > 0.01:
			adjusted += diff.normalized() * (MIN_TEAMMATE_SPACING - dist) * 0.72
			
	return adjusted

func _get_phase_blend_weight(phase: AttackPhase, role: TacticalRole) -> float:
	if role == TacticalRole.CENTER_BACK:
		return 0.65
	match phase:
		AttackPhase.TRANSITION:
			return 0.92
		AttackPhase.CROSS_SITUATION:
			return 0.90
		AttackPhase.FINAL_THIRD:
			return 0.85
		AttackPhase.PROGRESSION:
			return 0.80
		_:
			return 0.75

func _clamp_to_pitch_and_offside(pos: Vector3, ctx: Dictionary) -> Vector3:
	var out: Vector3 = pos
	out.x = clampf(out.x, -ctx.half_width + 2.0, ctx.half_width - 2.0)
	var clamped_prog: float = minf(ctx.attack_sign * out.z, ctx.safe_max_z_progress)
	out.z = clamped_prog * ctx.attack_sign
	return out


# ==============================================================================
# ANA GİRİŞ NOKTASI 2: SAVUNMA POZİSYONU (GEGENPRESSING & COVER SHADOW)
# ==============================================================================
func defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var form_pos: Vector3 = formation_position(player, attack_sign, false)
	var ball_pos: Vector3 = controller.ball.global_position + controller.ball.linear_velocity * 0.15
	var own_goal_z: float = -attack_sign * FIELD_HALF_LENGTH
	var spawn_x: float = player.spawn_position.x
	var role: TacticalRole = _infer_tactical_role(player, attack_sign)
	
	var target_pos: Vector3 = form_pos
	var dist_to_ball: float = player.global_position.distance_to(ball_pos)
	
	# 1. GEGENPRESSING (Top Kaybı Sonrası Şok Pres): Topa 14m'den yakınsa doğrudan baskı yap
	if dist_to_ball < 14.0 and role != TacticalRole.CENTER_BACK:
		var press_offset: Vector3 = Vector3(0.0, 0.0, -attack_sign * 1.2)
		return player.global_position.lerp(ball_pos + press_offset, 0.88)
		
	# 2. PAS KANALI KESME & KOMPAKT SAVUNMA (Mid-Block / Low-Block)
	var ball_in_our_half: bool = (ball_pos.z * attack_sign) < 0.0
	
	match role:
		TacticalRole.WINGER:
			# Kanat oyuncuları savunmada orta sahayı beşleyip rakip beklerin çıkışını kapatır
			var wing_z: float = ball_pos.z - (attack_sign * 7.0)
			if attack_sign > 0:
				wing_z = clampf(wing_z, own_goal_z + 18.0, 26.0)
			else:
				wing_z = clampf(wing_z, -26.0, own_goal_z - 18.0)
			target_pos.z = wing_z
			target_pos.x = lerpf(spawn_x * 0.72, ball_pos.x, 0.28)
			
		TacticalRole.STRIKER:
			if not ball_in_our_half:
				# Rakip stoperlerin oyun kurmasını bozmak için pas gölgesi oluştur (Cover Shadow)
				target_pos.z = ball_pos.z - (attack_sign * 8.5)
				target_pos.x = lerpf(ball_pos.x * 0.5, 0.0, 0.4)
			else:
				# Kontra Atak Pususu (Counter-Attack Outlet): Orta yuvarlak civarında bekler
				var outlet_z: float = -attack_sign * 6.0
				target_pos.z = lerpf(outlet_z, ball_pos.z + (attack_sign * 18.0), 0.35)
				target_pos.x = lerpf(spawn_x * 0.5, ball_pos.x * 0.45, 0.5)
				
		TacticalRole.DEFENSIVE_MID, TacticalRole.CENTRAL_MID:
			# Orta saha bloğu top ile kale arasına yerleşip merkez koridoru kilitler
			var mid_z: float = lerpf(ball_pos.z, own_goal_z, 0.38)
			target_pos.z = mid_z - (attack_sign * 3.5)
			target_pos.x = lerpf(spawn_x * 0.65, ball_pos.x * 0.55, 0.45)
			
		TacticalRole.CENTER_BACK, TacticalRole.FULLBACK:
			# Savunma dörtlüsü topun yönüne kayar (Ball-side Shifting) ve çizgiyi korur
			var def_z: float = lerpf(ball_pos.z, own_goal_z, 0.58)
			if attack_sign > 0:
				def_z = clampf(def_z, own_goal_z + 6.0, 8.0)
			else:
				def_z = clampf(def_z, -8.0, own_goal_z - 6.0)
			target_pos.z = def_z
			target_pos.x = lerpf(spawn_x * 0.78, ball_pos.x * 0.42, 0.45)
			
	target_pos.x = clampf(target_pos.x, -controller.FIELD_HALF_WIDTH + 3.0, controller.FIELD_HALF_WIDTH - 3.0)
	
	return form_pos.lerp(target_pos, 0.78)
