extends "res://match_role.gd"

func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var base_pos := formation_position(player, attack_sign, true)
	var ball_pos: Vector3 = controller.ball.global_position
	var is_wide := absf(player.spawn_position.x) > 10.0 # Kenar oyuncusu (Bek) kontrolü
	
	if is_wide:
		# Bek oyuncusu: Top kendi kanadındaysa hücuma bindirme yapar, ters kanattaysa merkeze yaklaşıp emniyet alır
		var same_side := signf(player.spawn_position.x) == signf(ball_pos.x)
		if same_side and is_instance_valid(carrier):
			base_pos.z = lerpf(base_pos.z, carrier.global_position.z + (attack_sign * 6.0), 0.5)
			base_pos.x = signf(player.spawn_position.x) * (controller.FIELD_HALF_WIDTH - 2.5)
		else:
			base_pos.x = lerpf(base_pos.x, 0.0, 0.35)
	else:
		# Stoper: Pas opsiyonu olmak için topun biraz gerisinde açılır ama orta sahayı pek geçmez
		base_pos.z = clampf(base_pos.z, -FIELD_HALF_LENGTH + 15.0, 8.0) if attack_sign > 0 else clampf(base_pos.z, -8.0, FIELD_HALF_LENGTH - 15.0)
		base_pos.x = lerpf(player.spawn_position.x, ball_pos.x * 0.4, 0.5)
		
	return base_pos


func defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var ball_pos: Vector3 = controller.ball.global_position + controller.ball.linear_velocity * 0.15
	var own_goal := Vector3(0.0, 0.0, -attack_sign * FIELD_HALF_LENGTH)
	var form_pos := formation_position(player, attack_sign, false)
	
	# 1. FIFA Savunma Çizgisi (Kompaktlık): Topa göre takım boyunu ayarlar ama kaleye çok gömülmez
	var ideal_line_z := lerpf(ball_pos.z - (attack_sign * 11.0), own_goal.z + (attack_sign * 7.5), 0.35)
	if attack_sign > 0:
		ideal_line_z = clampf(ideal_line_z, own_goal.z + 6.0, 12.0)
	else:
		ideal_line_z = clampf(ideal_line_z, -12.0, own_goal.z - 6.0)
		
	# 2. Yatay Kayma (Shifting): Top hangi kanattaysa savunma bloğu o tarafa kompakt kayar
	var shifted_x := lerpf(player.spawn_position.x * 0.75, ball_pos.x, 0.32)
	shifted_x = clampf(shifted_x, -controller.FIELD_HALF_WIDTH + 3.0, controller.FIELD_HALF_WIDTH - 3.0)
	
	var target_pos := Vector3(shifted_x, 0.0, ideal_line_z)
	
	# 3. Kademe ve Baskı (Jockey / Contain): Topa en yakın savunmacı açıyı kapatmak için öne çıkar
	var dist_to_ball := player.global_position.distance_to(ball_pos)
	if dist_to_ball < 14.0:
		# Top ile kale arasına girerek şut/pas açısını kapat (Jockey pozisyonu)
		var contain_pos := ball_pos.lerp(own_goal, 0.22)
		target_pos = target_pos.lerp(contain_pos, 0.75)
	else:
		# Diğer savunmacılar çizgiyi bozmadan hafifçe kademeye (derinliğe) girer
		target_pos.z -= attack_sign * 1.5
		
	return form_pos.lerp(target_pos, 0.8)
