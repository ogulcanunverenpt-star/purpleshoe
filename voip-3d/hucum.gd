extends "res://match_role.gd"

# Hücum Fazları
enum AttackPhase {
	BUILD_UP,       # Kendi yarı sahamızdan oyun kurma
	TRANSITION,     # Top yeni kazanıldı, hızlı dikine çıkış
	PROGRESSION,    # Orta sahada rakip blokları aşma
	FINAL_THIRD,    # Ceza sahası çevresi ve son vuruş organizasyonu
	CROSS_SITUATION # Kanattan orta / son çizgiye inme anı
}

# Koşu Tipleri (Oyuncuların birbirinin koşusunu anlaması için)
enum RunType {
	NONE,
	STRETCH_LINE,   # Çizgiye basıp oyunu genişletme
	HALF_SPACE_DIVE,# Bek-stoper arasına dikine koşu
	DROP_DEEP,      # Top almaya yaklaşma (False 9 / Pivot)
	OVERLAP,        # Top taşıyanın dışından bindirme
	UNDERLAP,       # Top taşıyanın içinden bindirme
	NEAR_POST,      # Ön direk koşusu
	FAR_POST,       # Arka direk koşusu
	CUTBACK_SPOT    # Penaltı noktası / yay gerisi bekleme
}

# Oyuncu bazlı anlık koşu hafızası (Titremeyi önlemek için)
var _player_run_memory: Dictionary = {}

func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var ctx: Dictionary = _build_attack_context(player, carrier, attack_sign)
	var phase: AttackPhase = _determine_attack_phase(ctx)
	var raw_target: Vector3 = ctx.form_pos
	
	match phase:
		AttackPhase.BUILD_UP:
			raw_target = _calc_buildup_position(ctx)
		AttackPhase.TRANSITION:
			raw_target = _calc_transition_position(ctx)
		AttackPhase.PROGRESSION:
			raw_target = _calc_progression_position(ctx)
		AttackPhase.FINAL_THIRD:
			raw_target = _calc_final_third_position(ctx)
		AttackPhase.CROSS_SITUATION:
			raw_target = _calc_cross_box_position(ctx)
			
	# Takım arkadaşlarıyla üst üste binmeyi engelle (Spacing / Anti-Clumping)
	raw_target = _apply_teammate_spacing(player, raw_target, ctx)
	
	# Formasyon ile taktiksel hedefi harmanla
	var blend_weight: float = _get_phase_blend_weight(phase)
	var final_pos: Vector3 = ctx.form_pos.lerp(raw_target, blend_weight)
	
	# Saha içi ve ofsayt sınırlarını kilitle
	return _clamp_to_pitch_and_offside(final_pos, ctx)


# -------------------------------------------------------------------------
# 1. BAĞLAM VE FAZ ANALİZİ (Burayı detaylı veriyle doldurabilirsin)
# -------------------------------------------------------------------------
func _build_attack_context(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Dictionary:
	var ball_pos: Vector3 = controller.ball.global_position
	var carrier_pos: Vector3 = carrier.global_position if is_instance_valid(carrier) else ball_pos
	var enemy_goal_z: float = attack_sign * FIELD_HALF_LENGTH
	var raw_offside: float = maxf(0.0, controller._offside_line_progress(player.team) - 1.25)
	var ball_prog: float = maxf(0.0, ball_pos.z * attack_sign)
	
	return {
		"player": player,
		"carrier": carrier,
		"attack_sign": attack_sign,
		"form_pos": formation_position(player, attack_sign, true),
		"ball_pos": ball_pos,
		"carrier_pos": carrier_pos,
		"enemy_goal_z": enemy_goal_z,
		"dist_to_enemy_goal": absf(enemy_goal_z - ball_pos.z),
		"ball_progress_ratio": clampf((ball_pos.z * attack_sign + FIELD_HALF_LENGTH) / (FIELD_HALF_LENGTH * 2.0), 0.0, 1.0),
		"is_winger": absf(player.spawn_position.x) > 9.5,
		"is_central_mid": absf(player.spawn_position.x) <= 9.5 and (player.spawn_position.z * attack_sign) < 5.0,
		"spawn_x": player.spawn_position.x,
		"slot": maxi(player.field_slot, 0),
		"safe_max_z_progress": maxf(raw_offside, ball_prog - 0.5)
	}

func _determine_attack_phase(ctx: Dictionary) -> AttackPhase:
	var prog: float = ctx.ball_progress_ratio
	var is_wide: bool = absf(ctx.ball_pos.x) > (controller.FIELD_HALF_WIDTH * 0.62)
	
	# Eğer top hızla rakip kaleye doğru gidiyorsa Geçiş Hücumu (Kontra)
	var ball_vel_z: float = controller.ball.linear_velocity.z * ctx.attack_sign
	if prog > 0.35 and prog < 0.75 and ball_vel_z > 8.5:
		return AttackPhase.TRANSITION
		
	if prog < 0.32:
		return AttackPhase.BUILD_UP
	elif prog < 0.68:
		return AttackPhase.PROGRESSION
	else:
		if is_wide and ctx.dist_to_enemy_goal < 22.0:
			return AttackPhase.CROSS_SITUATION
		return AttackPhase.FINAL_THIRD


# -------------------------------------------------------------------------
# 2. HÜCUM FAZI FONKSİYONLARI (600+ Satırlık Asıl Varyasyon Alanı)
# -------------------------------------------------------------------------
func _calc_buildup_position(ctx: Dictionary) -> Vector3:
	# TODO: Stoperler açılır, 6 numara (Regista) stoperlerin arasına girer (La Salida Lavolpiana),
	# Bekler çizgiye basar, santrafor ileride stoperleri kilitler.
	var pos: Vector3 = ctx.form_pos
	if ctx.is_winger:
		pos.x = signf(ctx.spawn_x) * (controller.FIELD_HALF_WIDTH - 2.5)
		pos.z = ctx.carrier_pos.z + (ctx.attack_sign * 18.0)
	else:
		# Merkez orta saha pas açısı (Triangle) oluşturmak için topun çaprazına kayar
		var side_shift: float = -signf(ctx.ball_pos.x) * 4.5 if absf(ctx.ball_pos.x) > 3.0 else 4.0
		pos.x = clampf(ctx.ball_pos.x + side_shift, -12.0, 12.0)
		pos.z = ctx.carrier_pos.z + (ctx.attack_sign * 11.0)
	return pos

func _calc_transition_position(ctx: Dictionary) -> Vector3:
	# TODO: Kontra atak koşuları! Topu alan oyuncunun önündeki 3 koridoru (Sol, Merkez, Sağ)
	# maksimum hızla doldurma ve savunma arkasına sprint atma mantığı.
	var pos: Vector3 = ctx.form_pos
	var lane_x: float = signf(ctx.spawn_x) * 11.5 if ctx.is_winger else (float((ctx.slot % 3) - 1) * 5.0)
	pos.x = lerpf(pos.x, lane_x, 0.75)
	pos.z = ctx.safe_max_z_progress * ctx.attack_sign
	return pos

func _calc_progression_position(ctx: Dictionary) -> Vector3:
	# TODO: Rakip orta saha bloğunu kırmak için "Half-Space" yerleşimi,
	# Overload-to-Isolate (bir kanatta yığılma, ters kanadı boş bırakma) ve verkaç üçgenleri.
	var pos: Vector3 = ctx.form_pos
	var same_side: bool = signf(ctx.spawn_x) == signf(ctx.ball_pos.x)
	
	if ctx.is_winger:
		if same_side:
			# Top kendi kanadındaysa genişlik ver
			pos.x = signf(ctx.spawn_x) * (controller.FIELD_HALF_WIDTH - 2.0)
			pos.z = ctx.carrier_pos.z + (ctx.attack_sign * 13.0)
		else:
			# Ters kanatsa iç koridora (Half-Space) devrilip oyun kurucuya dönüş
			pos.x = signf(ctx.spawn_x) * 8.5
			pos.z = ctx.carrier_pos.z + (ctx.attack_sign * 10.0)
	else:
		# Santrafor / Ofansif Orta Saha: Hatlar arası (Between the lines) boşluk arama
		pos.z = minf((ctx.carrier_pos.z + ctx.attack_sign * 16.0) * ctx.attack_sign, ctx.safe_max_z_progress) * ctx.attack_sign
		pos.x = lerpf(ctx.spawn_x, ctx.ball_pos.x * 0.4, 0.5)
	return pos

func _calc_final_third_position(ctx: Dictionary) -> Vector3:
	# TODO: Kapalı savunmaya karşı ceza sahası çevresi organizasyonları:
	# Tiki-taka duvar pasları, beklerin bindirmesi (Overlap/Underlap), ceza sahası yayında şut pozisyonu.
	var pos: Vector3 = ctx.form_pos
	if ctx.is_winger:
		pos.x = signf(ctx.spawn_x) * 8.2
		pos.z = ctx.enemy_goal_z - (ctx.attack_sign * 8.5)
	else:
		var dodge: float = -signf(ctx.carrier_pos.x) if absf(ctx.carrier_pos.x) > 2.0 else (1.0 if ctx.slot % 2 == 0 else -1.0)
		pos.x = clampf(ctx.carrier_pos.x + (dodge * 4.8), -7.5, 7.5)
		pos.z = ctx.enemy_goal_z - (ctx.attack_sign * 7.5)
	return pos

func _calc_cross_box_position(ctx: Dictionary) -> Vector3:
	# TODO: Ön direk, arka direk, penaltı noktası, ceza sahası yayı (Rebound) ve kanat oyuncusuna
	# geri pas (Cut-back) opsiyonlarının 5 bölgeye kusursuz dağılımı.
	var pos: Vector3 = ctx.form_pos
	var ball_side: float = signf(ctx.ball_pos.x)
	
	if ctx.is_winger:
		if signf(ctx.spawn_x) == ball_side:
			# Topu süren oyuncuya geri pas (Cut-back / Support) opsiyonu
			pos.x = ball_side * (controller.FIELD_HALF_WIDTH - 5.0)
			pos.z = ctx.carrier_pos.z - (ctx.attack_sign * 5.0)
		else:
			# Ters kanat arka direğe kapanır
			pos.x = -ball_side * 5.8
			pos.z = ctx.enemy_goal_z - (ctx.attack_sign * 6.2)
	else:
		if ctx.slot % 2 == 0:
			# Ön direk koşusu
			pos.x = ball_side * 4.2
			pos.z = ctx.enemy_goal_z - (ctx.attack_sign * 5.2)
		else:
			# Penaltı noktası / Cut-back bölgesi
			pos.x = -ball_side * 1.5
			pos.z = ctx.enemy_goal_z - (ctx.attack_sign * 11.0)
	return pos


# -------------------------------------------------------------------------
# 3. YARDIMCI VE KORUYUCU SİSTEMLER
# -------------------------------------------------------------------------
func _apply_teammate_spacing(player: CharacterBody3D, target: Vector3, ctx: Dictionary) -> Vector3:
	# Yakındaki takım arkadaşlarıyla aynı noktaya koşmayı engeller (İtme vektörü)
	var adjusted: Vector3 = target
	if controller.has_method("get_teammates"):
		for mate in controller.get_teammates(player.team):
			if mate == player or mate == ctx.carrier:
				continue
			var diff: Vector3 = adjusted - mate.global_position
			diff.y = 0.0
			var dist: float = diff.length()
			if dist < 4.5 and dist > 0.01:
				adjusted += diff.normalized() * (4.5 - dist) * 0.65
	return adjusted

func _get_phase_blend_weight(phase: AttackPhase) -> float:
	match phase:
		AttackPhase.TRANSITION: return 0.92
		AttackPhase.CROSS_SITUATION: return 0.90
		AttackPhase.FINAL_THIRD: return 0.85
		_: return 0.78

func _clamp_to_pitch_and_offside(pos: Vector3, ctx: Dictionary) -> Vector3:
	var out: Vector3 = pos
	out.x = clampf(out.x, -controller.FIELD_HALF_WIDTH + 2.0, controller.FIELD_HALF_WIDTH - 2.0)
	var clamped_prog: float = minf(ctx.attack_sign * out.z, ctx.safe_max_z_progress)
	out.z = clamped_prog * ctx.attack_sign
	return out
