extends "res://match_role.gd"

# ==============================================================================
# MODERN KALECİ (SWEEPER-KEEPER & SHOT-STOPPER) YAPAY ZEKA MOTORU
# ==============================================================================

enum KeeperState {
	SHOT_STOPPING,     # Çizgi ve açı kapatma pozisyonu (Şut tehlikesi)
	SWEEPING_OUT,      # Savunma arkasına atılan derin toplara çıkış (Sweeper-Keeper)
	CLAIMING_CROSS,    # Ceza sahası içi yüksek/yavaş sahipsiz topu kontrol etme
	NARROWING_ANGLE,   # Bire bir (1v1) pozisyonda açıyı daraltarak üzerine kapanma
	BUILDUP_SUPPORT,   # Takım hücumdayken geriden oyun kurma pas istasyonu (Libero)
	RECOVERY_RETREAT   # İleride yakalandığında hızla kale çizgisine geri çekilme
}

enum ThreatZone {
	SAFE_DISTANT,      # Top rakip yarı sahada veya orta alanda
	MID_BUILDUP,       # Rakip orta sahayı geçmiş, ceza sahası dışında
	DANGER_CENTRAL,    # Ceza sahası yayı ve merkez şut bölgesi
	DANGER_WIDE,       # Kanat ortası / son çizgi (Cut-back) tehlikesi
	ONE_ON_ONE         # Rakip forvet savunma hattını geçmiş, kaleciyle karşı karşıya
}

# Kaleci durum kilidi (Ani karar değişimlerinde titremeyi önler)
var _keeper_memory: Dictionary = {}

const STATE_LOCK_MS: int = 320
const MAX_SWEEP_DISTANCE: float = 26.0
const CROSS_CLAIM_RADIUS: float = 11.5
const ONE_V_ONE_TRIGGER_DIST: float = 17.5


# ==============================================================================
# ANA GİRİŞ NOKTASI: KALECİ HEDEF POZİSYONU
# ==============================================================================
func keeper_target(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var ctx: Dictionary = _build_keeper_context(player, attack_sign)
	
	# 1. ACİL DURUM: Kaleye doğru hızlı bir şut veya yönelmiş top varsa refleks/kurtarış hesabı
	var shot_intercept: Dictionary = _evaluate_incoming_shot(ctx)
	if shot_intercept.is_shot:
		controller._try_ai_keeper_dive(player, attack_sign)
		return _clamp_to_goal_mouth(shot_intercept.target_pos, ctx)
		
	# 2. SAHİPSİZ TOP TOPLAMA (Loose Ball / Cross Claim)
	if _should_claim_loose_ball(ctx):
		controller._try_ai_keeper_dive(player, attack_sign)
		return Vector3(ctx.ball_pos.x, 0.0, ctx.ball_pos.z)
		
	# 3. TEHDİT BÖLGESİ VE TAKTİKSEL DURUM BELİRLEME
	var threat: ThreatZone = _assess_threat_zone(ctx)
	var state: KeeperState = _resolve_keeper_state(ctx, threat)
	
	var target: Vector3 = ctx.default_pos
	match state:
		KeeperState.BUILDUP_SUPPORT:
			target = _calc_buildup_libero_pos(ctx)
		KeeperState.SWEEPING_OUT:
			target = _calc_sweeper_intercept_pos(ctx)
		KeeperState.NARROWING_ANGLE:
			target = _calc_one_on_one_angle_pos(ctx)
		KeeperState.CLAIMING_CROSS:
			target = _calc_cross_positioning(ctx)
		KeeperState.RECOVERY_RETREAT:
			target = _calc_retreat_pos(ctx)
		KeeperState.SHOT_STOPPING:
			target = _calc_angle_bisector_pos(ctx, threat)
			
	# Uzanma / atlama kontrolünü her karede canlı tut
	controller._try_ai_keeper_dive(player, attack_sign)
	
	return _apply_safety_clamps(target, state, ctx)


# ==============================================================================
# BAĞLAM OLUŞTURMA VE TEHDİT ANALİZİ
# ==============================================================================
func _build_keeper_context(player: CharacterBody3D, attack_sign: float) -> Dictionary:
	var ball_pos: Vector3 = controller.ball.global_position
	var ball_vel: Vector3 = controller.ball.linear_velocity
	var goal_line_z: float = -attack_sign * FIELD_HALF_LENGTH
	var goal_center: Vector3 = Vector3(0.0, 0.0, goal_line_z)
	var default_z: float = -attack_sign * (FIELD_HALF_LENGTH - 2.6)
	
	# Topun kalemize olan ilerleme mesafesi (0 = Kale çizgisi, pozitif = sahaya doğru)
	var ball_dist_from_goal_line: float = (ball_pos.z - goal_line_z) * attack_sign
	var keeper_dist_from_goal_line: float = (player.global_position.z - goal_line_z) * attack_sign
	
	# Top bizim takımımızda mı?
	var we_have_ball: bool = _is_ball_ours(player)
	
	return {
		"player": player,
		"player_id": player.get_instance_id(),
		"attack_sign": attack_sign,
		"ball_pos": ball_pos,
		"ball_vel": ball_vel,
		"ball_speed": ball_vel.length(),
		"goal_line_z": goal_line_z,
		"goal_center": goal_center,
		"default_pos": Vector3(clampf(ball_pos.x * 0.25, -GOAL_HALF_WIDTH + 0.6, GOAL_HALF_WIDTH - 0.6), 0.0, default_z),
		"ball_dist_from_goal": ball_dist_from_goal_line,
		"keeper_dist_from_goal": keeper_dist_from_goal_line,
		"we_have_ball": we_have_ball,
		"is_ball_free": controller.ball_owner_name.is_empty(),
		"penalty_width": controller.PENALTY_AREA_HALF_WIDTH,
		"penalty_depth": controller.PENALTY_AREA_DEPTH
	}

func _is_ball_ours(player: CharacterBody3D) -> bool:
	if controller.ball_owner_name.is_empty():
		return false
	if controller.has_method("get_teammates"):
		for mate in controller.get_teammates(player.team):
			if is_instance_valid(mate) and mate.name == controller.ball_owner_name:
				return true
	return false

func _assess_threat_zone(ctx: Dictionary) -> ThreatZone:
	var dist_z: float = ctx.ball_dist_from_goal
	var abs_x: float = absf(ctx.ball_pos.x)
	
	if dist_z > 48.0:
		return ThreatZone.SAFE_DISTANT
		
	if dist_z > ctx.penalty_depth + 10.0:
		return ThreatZone.MID_BUILDUP
		
	# Ceza sahası civarı veya içi
	if abs_x > ctx.penalty_width * 0.85:
		return ThreatZone.DANGER_WIDE
		
	# Top merkezde ve ceza sahasına çok yakınsa 1v1 ihtimalini kontrol et
	if dist_z < ONE_V_ONE_TRIGGER_DIST and not ctx.we_have_ball:
		if _is_attacker_clear_through(ctx):
			return ThreatZone.ONE_ON_ONE
			
	return ThreatZone.DANGER_CENTRAL

func _is_attacker_clear_through(ctx: Dictionary) -> bool:
	# Topun sahibi ile kaleci arasında başka savunma oyuncusu var mı kontrol eder
	if not controller.has_method("get_teammates"):
		return ctx.ball_dist_from_goal < 13.5
		
	var defenders_between: int = 0
	for mate in controller.get_teammates(ctx.player.team):
		if not is_instance_valid(mate) or mate == ctx.player:
			continue
		var def_dist_from_goal: float = (mate.global_position.z - ctx.goal_line_z) * ctx.attack_sign
		if def_dist_from_goal < ctx.ball_dist_from_goal + 1.5:
			if absf(mate.global_position.x - ctx.ball_pos.x) < 6.5:
				defenders_between += 1
				
	return defenders_between == 0


# ==============================================================================
# ŞUT TAHMİNİ VE SAHİPSİZ TOP KONTROLÜ
# ==============================================================================
func _evaluate_incoming_shot(ctx: Dictionary) -> Dictionary:
	var vz: float = ctx.ball_vel.z
	var sign_a: float = ctx.attack_sign
	
	# Top kalemize doğru yeterli hızla geliyorsa (vz * sign_a < 0)
	if absf(vz) > 2.2 and (vz * sign_a) < 0.0:
		var time_to_goal: float = (ctx.goal_line_z - ctx.ball_pos.z) / vz
		if time_to_goal >= 0.0 and time_to_goal < 2.8:
			var predicted_x: float = ctx.ball_pos.x + ctx.ball_vel.x * time_to_goal
			# Top kaleye veya yakın çevresine yönelmişse kesişme noktasına git
			if absf(predicted_x) < GOAL_HALF_WIDTH + 3.5:
				var intercept_z: float = lerpf(ctx.goal_line_z + (sign_a * 1.4), ctx.player.global_position.z, 0.35)
				# Kale çizgisinin arkasına geçmesini engelle
				if sign_a > 0:
					intercept_z = maxf(intercept_z, ctx.goal_line_z + 0.8)
				else:
					intercept_z = minf(intercept_z, ctx.goal_line_z - 0.8)
					
				return {
					"is_shot": true,
					"target_pos": Vector3(predicted_x, 0.0, intercept_z)
				}
				
	return {"is_shot": false, "target_pos": Vector3.ZERO}

func _should_claim_loose_ball(ctx: Dictionary) -> bool:
	if not ctx.is_ball_free:
		return false
	if ctx.ball_pos.y > 1.35:
		return false
		
	var in_box_x: bool = absf(ctx.ball_pos.x) < ctx.penalty_width
	var in_box_z: bool = ctx.ball_dist_from_goal < ctx.penalty_depth
	
	# Ceza sahası içindeki yavaş sahipsiz toplar
	if in_box_x and in_box_z and ctx.ball_speed < 6.5:
		return true
		
	# Savunma arkasına atılmış ama yavaşlamış toplar (Sweeper Claim)
	if ctx.ball_dist_from_goal < MAX_SWEEP_DISTANCE and ctx.ball_speed < 4.5:
		if _can_keeper_reach_ball_first(ctx):
			return true
			
	return false


# ==============================================================================
# DURUM ÇÖZÜMLEME VE HAFIZA KİLİDİ
# ==============================================================================
func _resolve_keeper_state(ctx: Dictionary, threat: ThreatZone) -> KeeperState:
	var pid: int = ctx.player_id
	var now: int = Time.get_ticks_msec()
	
	# Acil durumlar hafıza kilidini geçersiz kılar
	if threat == ThreatZone.ONE_ON_ONE:
		return KeeperState.NARROWING_ANGLE
		
	# Savunma arkasına derin ara pas atıldıysa (Sweeper-Keeper çıkışı)
	if _is_through_ball_sweep_opportunity(ctx):
		return KeeperState.SWEEPING_OUT
		
	# Kaleci çok ileride yakalandı ve top rakibe geçtiyse hızla kaleye dön
	if not ctx.we_have_ball and ctx.keeper_dist_from_goal > 9.0 and ctx.ball_dist_from_goal < 38.0:
		return KeeperState.RECOVERY_RETREAT
		
	if _keeper_memory.has(pid):
		var mem: Dictionary = _keeper_memory[pid]
		if now < mem.expire_ms and mem.threat == threat:
			return mem.state
			
	var chosen: KeeperState = KeeperState.SHOT_STOPPING
	if ctx.we_have_ball and threat == ThreatZone.SAFE_DISTANT:
		chosen = KeeperState.BUILDUP_SUPPORT
	elif threat == ThreatZone.DANGER_WIDE:
		chosen = KeeperState.CLAIMING_CROSS
	else:
		chosen = KeeperState.SHOT_STOPPING
		
	_keeper_memory[pid] = {
		"state": chosen,
		"threat": threat,
		"expire_ms": now + STATE_LOCK_MS
	}
	return chosen

func _is_through_ball_sweep_opportunity(ctx: Dictionary) -> bool:
	if not ctx.is_ball_free:
		return false
	if ctx.ball_dist_from_goal > MAX_SWEEP_DISTANCE or ctx.ball_dist_from_goal < ctx.penalty_depth * 0.7:
		return false
	# Top kalemize doğru yuvarlanıyorsa ve hızı kontrol edilebilir seviyedeyse
	var moving_towards_us: bool = (ctx.ball_vel.z * ctx.attack_sign) < -1.5
	if moving_towards_us and ctx.ball_speed < 14.0:
		return _can_keeper_reach_ball_first(ctx)
	return false

func _can_keeper_reach_ball_first(ctx: Dictionary) -> bool:
	var keeper_dist: float = ctx.player.global_position.distance_to(ctx.ball_pos)
	if not controller.has_method("get_opponents"):
		return keeper_dist < 14.0
		
	var closest_opp_dist: float = 999.0
	for opp in controller.get_opponents(ctx.player.team):
		if not is_instance_valid(opp):
			continue
		var d: float = opp.global_position.distance_to(ctx.ball_pos)
		if d < closest_opp_dist:
			closest_opp_dist = d
			
	# Kaleci en yakın rakipten en az 2.5 metre daha yakınsa çıkış güvenlidir
	return keeper_dist + 2.5 < closest_opp_dist


# ==============================================================================
# TAKTİKSEL KALECİ POZİSYON VEKTÖRLERİ
# ==============================================================================

# 1. AÇI ORTAYI KESME (Angle Bisector Positioning - Temel Kalecilik Geometrisi)
func _calc_angle_bisector_pos(ctx: Dictionary, threat: ThreatZone) -> Vector3:
	var left_post: Vector3 = Vector3(-GOAL_HALF_WIDTH, 0.0, ctx.goal_line_z)
	var right_post: Vector3 = Vector3(GOAL_HALF_WIDTH, 0.0, ctx.goal_line_z)
	var ball_flat: Vector3 = Vector3(ctx.ball_pos.x, 0.0, ctx.ball_pos.z)
	
	# Topun iki direkle yaptığı açının açıortay vektörünü bul
	var to_left: Vector3 = (left_post - ball_flat).normalized()
	var to_right: Vector3 = (right_post - ball_flat).normalized()
	var bisector: Vector3 = (to_left + to_right).normalized()
	
	# Topun kaleye uzaklığına göre çizgiden ne kadar öne çıkacağını belirle
	var advance_depth: float = 2.2
	if threat == ThreatZone.SAFE_DISTANT:
		advance_depth = 7.5
	elif threat == ThreatZone.MID_BUILDUP:
		advance_depth = 4.6
	elif threat == ThreatZone.DANGER_CENTRAL:
		advance_depth = 2.8
		
	# Kale merkezinden topa doğru açıortay boyunca ilerle
	var ray_from_goal: Vector3 = -bisector
	var target: Vector3 = ctx.goal_center + (ray_from_goal * advance_depth)
	
	# X ekseninde kale direkleri dışına taşmayı sınırla
	var max_x: float = GOAL_HALF_WIDTH - 0.55
	target.x = clampf(target.x, -max_x, max_x)
	return target

# 2. KANAT ORTASI VE CUT-BACK POZİSYONU (Claiming Cross)
func _calc_cross_positioning(ctx: Dictionary) -> Vector3:
	var sign_a: float = ctx.attack_sign
	var ball_side: float = signf(ctx.ball_pos.x)
	
	# Ön direği kapatırken ceza sahası ortasına yapılacak ortalara da çıkabilecek derinlikte dur
	var target_x: float = ball_side * (GOAL_HALF_WIDTH * 0.58)
	var target_z: float = ctx.goal_line_z + (sign_a * 2.4)
	
	# Top son çizgiye çok indiyse (Cut-back tehlikesi) ön direğe biraz daha yapış
	if ctx.ball_dist_from_goal < 7.0:
		target_x = ball_side * (GOAL_HALF_WIDTH * 0.72)
		target_z = ctx.goal_line_z + (sign_a * 1.5)
		
	return Vector3(target_x, 0.0, target_z)

# 3. BİRE BİR AÇI DARALTMA (1v1 Narrowing Angle / Smothering)
func _calc_one_on_one_angle_pos(ctx: Dictionary) -> Vector3:
	var ball_flat: Vector3 = Vector3(ctx.ball_pos.x, 0.0, ctx.ball_pos.z)
	var to_ball: Vector3 = (ball_flat - ctx.goal_center)
	var dist: float = to_ball.length()
	
	if dist < 0.1:
		return ctx.default_pos
		
	# Topa doğru kontrollü şekilde açıyı kapatarak yaklaş (Smother distance: topa 3.2m kalana kadar)
	var desired_advance: float = clampf(dist - 3.2, 2.0, 9.5)
	return ctx.goal_center + (to_ball.normalized() * desired_advance)

# 4. SWEEPER-KEEPER ÇIKIŞI (Sweeping Out)
func _calc_sweeper_intercept_pos(ctx: Dictionary) -> Vector3:
	# Topun 0.35 saniye sonraki tahmini noktasına doğru sprint at
	var future_ball: Vector3 = ctx.ball_pos + (ctx.ball_vel * 0.35)
	future_ball.y = 0.0
	return future_ball

# 5. GERİDEN OYUN KURMA DESTEĞİ (Libero / Build-Up Support)
func _calc_buildup_libero_pos(ctx: Dictionary) -> Vector3:
	var sign_a: float = ctx.attack_sign
	# Top bizdeyken ve rakip sahadayken ceza sahası yayı civarına kadar çıkıp pas opsiyonu olur
	var support_z: float = ctx.goal_line_z + (sign_a * clampf(ctx.ball_dist_from_goal * 0.28, 7.0, 19.0))
	# Topun bulunduğu kanadın hafif tersine kayarak temiz geri pas açısı (Switch angle) sunar
	var support_x: float = clampf(-ctx.ball_pos.x * 0.22, -5.5, 5.5)
	return Vector3(support_x, 0.0, support_z)

# 6. HIZLI GERİ ÇEKİLME (Recovery Retreat)
func _calc_retreat_pos(ctx: Dictionary) -> Vector3:
	var sign_a: float = ctx.attack_sign
	var retreat_z: float = ctx.goal_line_z + (sign_a * 2.2)
	var retreat_x: float = clampf(ctx.ball_pos.x * 0.25, -GOAL_HALF_WIDTH + 0.6, GOAL_HALF_WIDTH - 0.6)
	return Vector3(retreat_x, 0.0, retreat_z)


# ==============================================================================
# GÜVENLİK SINIRLARI VE KALE ÇİZGİSİ KİLİDİ
# ==============================================================================
func _clamp_to_goal_mouth(pos: Vector3, ctx: Dictionary) -> Vector3:
	var max_x: float = GOAL_HALF_WIDTH - 0.55
	var safe_z: float = pos.z
	if ctx.attack_sign > 0:
		safe_z = clampf(safe_z, ctx.goal_line_z + 0.65, ctx.goal_line_z + 6.0)
	else:
		safe_z = clampf(safe_z, ctx.goal_line_z - 6.0, ctx.goal_line_z - 0.65)
	return Vector3(clampf(pos.x, -max_x, max_x), 0.0, safe_z)

func _apply_safety_clamps(pos: Vector3, state: KeeperState, ctx: Dictionary) -> Vector3:
	# Sweeper çıkışı ve oyun kurma dışındaki tüm durumlarda kale ağzı güvenliğini koru
	if state == KeeperState.SWEEPING_OUT:
		var max_x: float = controller.FIELD_HALF_WIDTH - 3.0
		return Vector3(clampf(pos.x, -max_x, max_x), 0.0, pos.z)
		
	if state == KeeperState.BUILDUP_SUPPORT:
		return Vector3(clampf(pos.x, -9.0, 9.0), 0.0, pos.z)
		
	if state == KeeperState.NARROWING_ANGLE:
		var max_x_1v1: float = ctx.penalty_width - 1.5
		return Vector3(clampf(pos.x, -max_x_1v1, max_x_1v1), 0.0, pos.z)
		
	return _clamp_to_goal_mouth(pos, ctx)
