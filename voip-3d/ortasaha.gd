extends "res://match_role.gd"

func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var form_pos := formation_position(player, attack_sign, true)
	var ball_pos: Vector3 = controller.ball.global_position
	var carrier_pos: Vector3 = carrier.global_position if is_instance_valid(carrier) else ball_pos
	
	# Oyuncunun sahadaki diziliş karakterini belirle
	var is_wide := absf(player.spawn_position.x) > 11.0
	var is_defensive_mid: bool = (player.spawn_position.z * attack_sign) < -3.0 and not is_wide
	var is_attacking_mid: bool = (player.spawn_position.z * attack_sign) > 3.0 and not is_wide

	
	var target_pos := form_pos
	
	# 1. Pas Üçgeni Oluşturma (FIFA Passing Triangles)
	# Topu taşıyan oyuncunun görüş açısında kalmak için hafif çapraz açılma
	var side_offset := signf(player.spawn_position.x - carrier_pos.x)
	if is_zero_approx(side_offset):
		side_offset = 1.0 if (player.field_slot % 2 == 0) else -1.0
		
	if is_defensive_mid:
		# 6 Numara (Regista / Çapa): Topun 7-9 metre gerisinde ve çaprazında güvenli geri pas istasyonu olur
		target_pos.z = carrier_pos.z - (attack_sign * 8.5)
		target_pos.x = lerpf(carrier_pos.x + (side_offset * 6.5), 0.0, 0.35)
		# Rakip kaleye çok yaklaşmaz, kontra atak sigortası olarak merkezde kalır
		if attack_sign > 0:
			target_pos.z = minf(target_pos.z, 18.0)
		else:
			target_pos.z = maxf(target_pos.z, -18.0)
			
	elif is_attacking_mid:
		# 10 Numara (Playmaker): Rakip defans ile orta saha arasındaki boşluğa (Half-Space) sızar
		target_pos.z = carrier_pos.z + (attack_sign * 10.5)
		target_pos.x = lerpf(ball_pos.x + (side_offset * 7.5), player.spawn_position.x, 0.3)
		# Ceza sahası yayına doğru gizli koşu (Late Run)
		var dist_to_enemy_goal := absf((attack_sign * FIELD_HALF_LENGTH) - carrier_pos.z)
		if dist_to_enemy_goal < 26.0:
			target_pos.z = (attack_sign * FIELD_HALF_LENGTH) - (attack_sign * 13.5)
			target_pos.x = clampf(target_pos.x, -9.0, 9.0)
			
	elif is_wide:
		# Kanat Orta Sahalar (SĞO / SLO): Çizgiye basıp oyunu genişletir veya ters kanattaysa ceza sahasına kat eder
		var same_flank := signf(player.spawn_position.x) == signf(ball_pos.x)
		if same_flank:
			target_pos.x = signf(player.spawn_position.x) * (controller.FIELD_HALF_WIDTH - 2.0)
			target_pos.z = carrier_pos.z + (attack_sign * 9.0)
		else:
			# Ters kanat oyuncusu arka direğe doğru gizli forvet gibi içeri sızar (Cut Inside)
			target_pos.x = signf(player.spawn_position.x) * 8.5
			target_pos.z = carrier_pos.z + (attack_sign * 11.5)
	else:
		# 8 Numara (Box-to-Box): Topun hizasında dinamik destek verir, ileri-geri mekik dokur
		target_pos.z = carrier_pos.z + (attack_sign * 5.0)
		target_pos.x = carrier_pos.x + (side_offset * 9.5)
		
	# Saha sınırları içinde tut ve diğer oyuncularla üst üste binmeyi önle
	target_pos.x = clampf(target_pos.x, -controller.FIELD_HALF_WIDTH + 2.5, controller.FIELD_HALF_WIDTH - 2.5)
	target_pos.z = clampf(target_pos.z, -FIELD_HALF_LENGTH + 4.0, FIELD_HALF_LENGTH - 4.0)
	
	return form_pos.lerp(target_pos, 0.78)


func defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var form_pos := formation_position(player, attack_sign, false)
	var ball_pos: Vector3 = controller.ball.global_position + controller.ball.linear_velocity * 0.2
	var own_goal := Vector3(0.0, 0.0, -attack_sign * FIELD_HALF_LENGTH)
	
	var is_wide := absf(player.spawn_position.x) > 11.0
	var is_defensive_mid: bool = (player.spawn_position.z * attack_sign) < -3.0 and not is_wide

	
	# 1. Blok Kompaktlığı: Defans hattının yaklaşık 9-12 metre önünde ikinci bir duvar örer
	var block_z := ball_pos.z - (attack_sign * (6.5 if is_defensive_mid else 9.0))
	
	# Kendi ceza sahasına çok gömülüp yay önünü boş bırakmamak için sınır koy
	if attack_sign > 0:
		block_z = clampf(block_z, own_goal.z + 14.0, 22.0)
	else:
		block_z = clampf(block_z, -22.0, own_goal.z - 14.0)
		
	# 2. Yatay Daralma (Compact Shifting): Top merkezdeyse veya ters kanattaysa içeri kapanır
	var compact_factor := 0.55 if is_wide else 0.7
	var target_x := lerpf(ball_pos.x, player.spawn_position.x * compact_factor, 0.45)
	
	var target_pos := Vector3(target_x, 0.0, block_z)
	
	# 3. Pas Kanalı Kapatma (Passing Lane Interception) & Aktif Pres
	var dist_to_ball := player.global_position.distance_to(ball_pos)
	
	if dist_to_ball < 12.0:
		# Topa en yakın orta saha oyuncusu doğrudan baskıya (Pressing) gider
		var press_pos := ball_pos.lerp(own_goal, 0.12)
		target_pos = target_pos.lerp(press_pos, 0.85)
	elif is_defensive_mid:
		# 6 Numara, top ile kendi ceza sahası yayının tam arasına (Zone 14) yerleşip ara pasları keser
		var zone_14 := Vector3(clampf(ball_pos.x * 0.4, -7.0, 7.0), 0.0, own_goal.z + (attack_sign * 18.0))
		target_pos = target_pos.lerp(zone_14, 0.55)
	else:
		# Diğer orta sahalar top ile kendi kalesi arasındaki çapraz pas açılarını kapatır
		var lane_block := ball_pos.lerp(own_goal, 0.28)
		target_pos.x = lerpf(target_pos.x, lane_block.x + (player.spawn_position.x * 0.25), 0.5)
		
	target_pos.x = clampf(target_pos.x, -controller.FIELD_HALF_WIDTH + 3.0, controller.FIELD_HALF_WIDTH - 3.0)
	
	return form_pos.lerp(target_pos, 0.75)
