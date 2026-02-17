--!strict
local UserInputService = game:GetService('UserInputService')
local StarterPlayer = game:GetService('StarterPlayer')
local TweenService = game:GetService('TweenService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local Assets = ReplicatedStorage:WaitForChild("Assets")
local Animations = Assets:WaitForChild("Animations")
local Particles = Assets:WaitForChild("Particles")

local character = (script.Parent :: any) :: Model
local humanoid = character:WaitForChild('Humanoid') :: Humanoid
local animator = humanoid:WaitForChild('Animator') :: Animator
local humanoidRootPart = character:WaitForChild('HumanoidRootPart') :: BasePart

-- Modulescript that stores the animationIDs of all movement animations.
local MovementAnimations = require(Animations:WaitForChild("MovementAnimations"))

-- Store the dash key, force, duration, cooldown, and vault cooldown as constants (UPPER_SNAKE_CASE) to make them easy to change later.
local DASH_KEY = Enum.KeyCode.C
local DASH_FORCE = 45
local DASH_DURATION = 0.3
local DASH_COOLDOWN = 1
local VAULT_COOLDOWN = 0.5

-- Debounce variables to prevent spamming of dashes and vaults
local vaultDebounce = os.clock()
local dashDebounce = os.clock()

-- Boolean varibles to know when the character is atached to a ledge, or if they're able to vault over a part.
local canVault: boolean = true
local isLedgeGrabbed: boolean = false

-- Global variable to store the ledge part and the distance between the character and the ledge.
local ledgePartGlobal: BasePart? = nil

-- Connection for when the character is attached to a ledge, disconnects when the character is not attached to a ledge.
local ledgeConnection: RBXScriptConnection? = nil

-- Character is airbone if they're standing on air.
local function isAirbone(): boolean
	return humanoid.FloorMaterial == Enum.Material.Air
end

-- Create raycastParams filtering out the chracter's bodyparts so that they dont interfere with the raycast.
local function createRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = character:GetChildren()
	params.FilterType = Enum.RaycastFilterType.Exclude

	return params
end

-- Create BodyVelocity, excluding the Y axis since it is never needed.
local function createBodyVelocity(x: number, z: number, length: number)
	local bodyVelocity = Instance.new('BodyVelocity')
	bodyVelocity.MaxForce = Vector3.new(30000, 0, 30000)
	-- Apply the velocity relative the the character's CFrame, so that the directions remain consistent.
	bodyVelocity.Velocity = humanoidRootPart.CFrame:VectorToWorldSpace(Vector3.new(x, 0, z))

	bodyVelocity.Parent = humanoidRootPart

	game.Debris:AddItem(bodyVelocity, length)
end

-- Play animation by creating an Animation instance and loading it to the animator.
-- Destroy the animation instance once the animation has ended to conserve memory.
local function playAnimation(animationID: string, weight: Enum.AnimationPriority?, speed: number?)
	local animation = Instance.new("Animation")
	animation.AnimationId = animationID
	
	local animationTrack = animator:LoadAnimation(animation)
	local connection: RBXScriptConnection

	connection = animationTrack.Ended:Connect(function() 
		animation:Destroy()
		animationTrack:Destroy()
		
		connection:Disconnect()
	end)
	
	animationTrack:Play(nil, weight and weight.Value, speed)
end

-- Get the AnimationTrack by looping through all currently playing animation tracks.
-- And finding one with the same animationID passed as an argument
local function getAnimationTrack(animationID: string): AnimationTrack?
	for _, track in animator:GetPlayingAnimationTracks() do
		local animation = track.Animation :: Animation

		if animation.AnimationId == animationID then
			return track
		end
	end

	return nil
end

-- Stop the animation by getting the animationTrack with the same AnimationID and stopping it.
local function stopAnimation(animationID: string)
	local animationTrack = getAnimationTrack(animationID)
	
	if animationTrack then
		animationTrack:Stop()
		animationTrack:Destroy()
	end
end

----------- VAULTING ----------------
local function vault(vaultedPart: BasePart, wasVaulting: boolean): ()
	local oldJumpPower = humanoid.JumpPower -- Store jump power because we are changing it.

	-- Force character to jump (jumping normally would cause the character to get stuck).
	humanoid.JumpPower = 2000
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	humanoid.JumpPower = oldJumpPower

	playAnimation(MovementAnimations.Vault)

	-- Prevent character from turning while vaulting.
	-- For all MaxForces and MaxTorques, do not use math.huge to prevent clipping into walls or flinging.
	local bodyGyro = Instance.new('BodyGyro')
	bodyGyro.MaxTorque = Vector3.new(30000, 30000, 30000)
	bodyGyro.CFrame = CFrame.new(humanoidRootPart.Position, humanoidRootPart.CFrame.LookVector * 100)
	bodyGyro.Parent = humanoidRootPart

	game.Debris:AddItem(bodyGyro, 0.35)

	local bodyVelocity = Instance.new('BodyVelocity') -- Up velocity
	bodyVelocity.MaxForce = Vector3.new(30000, 30000, 30000)
	bodyVelocity.Velocity = humanoidRootPart.CFrame.UpVector * Vector3.new(0, vaultedPart.Size.Y * 2.5, 0)
	bodyVelocity.Parent = humanoidRootPart

	game.Debris:AddItem(bodyVelocity, 0.1)

	task.wait(0.2) -- Delay foward velocity so character doesnt get forced into the part they're vaulting.

	local bodyVelocity = Instance.new('BodyVelocity') -- Foward velocity
	bodyVelocity.MaxForce = Vector3.new(30000, 30000, 30000)
	bodyVelocity.Velocity = humanoidRootPart.CFrame.LookVector * 15 - Vector3.new(0, vaultedPart.Size.Y * 1.5, 0)
	bodyVelocity.Parent = humanoidRootPart

	game.Debris:AddItem(bodyVelocity, 0.25)

end

local function getVaultable(): BasePart?
	local raycastParams = createRaycastParams()
	local raycastResults = workspace:Raycast(humanoidRootPart.CFrame.Position, humanoidRootPart.CFrame.LookVector * 3, raycastParams)
	-- Raycast 3 studs infront of the character to check if there is a part to vault on.
	
	if raycastResults and not isLedgeGrabbed then
		local head = character:FindFirstChild('Head') :: BasePart
		local part = raycastResults.Instance :: BasePart

		-- Get the world position of instance's ledge that was hit by the raycast.
		local positionToObject: Vector3 = part.CFrame:PointToObjectSpace(raycastResults.Position)
		local ledgePosition: Vector3 = Vector3.new(positionToObject.X, part.Size.Y / 2, positionToObject.Z)
		local positionToWorld: Vector3 = part.CFrame:PointToWorldSpace(ledgePosition)
		
		-- If that position is within 4 studs of the character's head, it is close enough to vault, so return the part.
		if (positionToWorld - head.Position).Magnitude < 4 then
			return part
		end
	end

	return nil
end

------------ Ledge grabbing -------------------
local function detectLedge(): (CFrame?, BasePart?)
	local raycastParams = createRaycastParams()
	local raycastResults = workspace:Raycast(humanoidRootPart.CFrame.Position, humanoidRootPart.CFrame.LookVector * 5, raycastParams)
	-- Raycast 5 studs infront of the character to check if theres a ledge to grab onto.
	
	if raycastResults then
		local raycastBasePart = raycastResults.Instance :: BasePart
		
		-- Get the world positon of the ledge, similar to the previous function.
		local positionToObject = raycastBasePart.CFrame:PointToObjectSpace(raycastResults.Position)
		local ledgePosition = Vector3.new(positionToObject.X, raycastBasePart.Size.Y / 2, positionToObject.Z)

		local positionToWorld = raycastBasePart.CFrame:PointToWorldSpace(ledgePosition)
		
		-- Get the offset CFrame of the ledge
		local ledgeOffset = CFrame.lookAt(positionToWorld, positionToWorld - raycastResults.Normal)

		local head = character:FindFirstChild('Head') :: BasePart

		if (positionToWorld - head.Position).Magnitude < 4 then
			-- Create a part to represent where the character should grab the ledge.
			local ledgePart = Instance.new('Part')

			ledgePart.Anchored = true
			ledgePart.CanTouch = false
			ledgePart.CanCollide = false
			ledgePart.CanQuery = false
			--Offset the Cframe so that the character is slightly ontop and behind the ledge, rather than being inside of it.
			ledgePart.CFrame = ledgeOffset + Vector3.new(0, -2, 0) + -ledgeOffset.LookVector
			ledgePart.Transparency = 1
			ledgePart.Parent = workspace

			return ledgeOffset, ledgePart
		end
	end

	return nil, nil
end

local function beginLedgeHold(ledgeOffset: CFrame, ledgePart: BasePart): ()
	playAnimation(MovementAnimations.LedgeBegin, Enum.AnimationPriority.Action3)
	
	isLedgeGrabbed = true
	canVault = false
	ledgePartGlobal = ledgePart
	
	-- Connect to the RenderStepped event to constantly update the position of the character to be attached to the ledge.
	ledgeConnection = RunService.RenderStepped:Connect(function()
		if ledgePart then
			-- Lerp the character's position to the ledge, also anchor and lock rotation so the character cannot move while attached to the ledge.
			local lerpCFrame = CFrame.new(ledgePart.CFrame.Position, (ledgePart.CFrame * CFrame.new(0, 0, -1)).Position)
			-- Using lerp to make the character move smoothly across the ledge.
			humanoidRootPart.CFrame = humanoidRootPart.CFrame:Lerp(lerpCFrame, 0.25)
			humanoidRootPart.Anchored = true
			humanoid.AutoRotate = false
		end
	end)
	
	playAnimation(MovementAnimations.LedgeHold, Enum.AnimationPriority.Movement)
	stopAnimation(MovementAnimations.DefaultAnimationLanded)
end

local function endLedgeHold(): ()
	humanoid.AutoRotate = true

	if isLedgeGrabbed then
		-- Store the original JumpPower and force the character to jump with a lower JumpPower so they don't fly over the ledge
		local oldJumpPower = humanoid.JumpPower

		humanoid.JumpPower = 20
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		playAnimation(MovementAnimations.Vault)

		humanoid.JumpPower = oldJumpPower
	end

	humanoidRootPart.Anchored = false

	-- Disconnect the RunService connection and destroy to LedgePart to conserve memory.
	if ledgeConnection then
		ledgeConnection:Disconnect()
	end

	if ledgePartGlobal then
		ledgePartGlobal:Destroy()
		ledgePartGlobal = nil
	end
	
	canVault = true
	isLedgeGrabbed = false
	
	stopAnimation(MovementAnimations.LedgeHold)
end

local function dashEffect(dashAnimationID: string)
	
	local animationTrack = getAnimationTrack(dashAnimationID)
	local start = os.clock()

	if animationTrack then
		-- Create a smoke effect that is visible when the character dashes, and use the animation track's length to know how long the smoke effect should run for.
		local animationLength = animationTrack.Length
		local particleBlock = Particles.Landing:Clone()
		particleBlock.Parent = workspace

		game.Debris:AddItem(particleBlock, 5)

		-- While the animation is playing, raycast down to find the exact position of the floor beneath the character to create a smoke effect.
		while os.clock() - start <= animationLength do
			local raycastParams = createRaycastParams()
			local results = workspace:Raycast(humanoidRootPart.Position, humanoidRootPart.CFrame.UpVector * -3, raycastParams)

			if results then
				local raycastBasePart = results.Instance :: BasePart
				
				-- Move the posiion up one stud to make it more visible.
				particleBlock.Position = results.Position + Vector3.new(0, 1, 0)
				particleBlock.Attachment.Smoke.Color = ColorSequence.new(raycastBasePart.Color)
				particleBlock.Attachment.Smoke.Enabled = true
			else
				particleBlock.Attachment.Smoke.Enabled = false
			end
			
			task.wait()
		end

		particleBlock.Attachment.Smoke.Enabled = false
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean) 
	if gameProcessedEvent then
		return
	end
	
	if isLedgeGrabbed then
		-- If user inputs A or D while holding onto a ledge, the character will move one stud in their respective directions. 
		if (input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.D) and ledgePartGlobal then
			local offset = if input.KeyCode == Enum.KeyCode.A then -1 else 1
			
			local raycastParams = createRaycastParams()
			-- Prevent the character from moving off the ledge by raycasting from the position they will move to and checking if theres still an instance at this position.
			local raycastResults = workspace:Raycast((ledgePartGlobal.CFrame * CFrame.new(offset, 0, 0)).Position, humanoidRootPart.CFrame.LookVector * 5, raycastParams)
			
			if raycastResults then
				ledgePartGlobal.CFrame = ledgePartGlobal.CFrame * CFrame.new(offset, 0, 0)
			end
		end
	end
	
	if input.KeyCode == Enum.KeyCode.Space then
		-- If the user is able to vault and they are airborne, then they are trying to grab onto a ledge.
		if canVault and isAirbone() then
			local ledgeOffset, ledgePart = detectLedge()

			if ledgeOffset and ledgePart then
				beginLedgeHold(ledgeOffset, ledgePart)
			end
		-- If the user presses space and they are already on a ledge, then let go of the ledge
		elseif isLedgeGrabbed then
			endLedgeHold()
		end
		-- We put this check last to ensure that if the user presses space on a ledge, they will always vault over the ledge
		
		-- If the humanoid isnt falling, then value over the part infront of them if detected.
		if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
			local vaultablePart = getVaultable()
			
			if vaultablePart then
				vault(vaultablePart, isLedgeGrabbed)
			end
		end
	elseif input.KeyCode == DASH_KEY and (os.clock() - dashDebounce) >= DASH_COOLDOWN then
		dashDebounce = os.clock()
		-- Check if each movment key is being pressed, if none are default to dashing backwards.
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then -- Right
			playAnimation(MovementAnimations.DashRight, Enum.AnimationPriority.Action4, 1.25)
			createBodyVelocity(-DASH_FORCE, 0, DASH_DURATION) -- create body velocity with a force in the negative x direction to simluate a dash to the right.
			dashEffect(MovementAnimations.DashRight)

		elseif UserInputService:IsKeyDown(Enum.KeyCode.D) then -- Left
			playAnimation(MovementAnimations.DashLeft, Enum.AnimationPriority.Action4, 1.25)
			createBodyVelocity(DASH_FORCE, 0, DASH_DURATION)  -- create body velocity with a force in the positive x direction to simluate a dash to the left.
			dashEffect(MovementAnimations.DashLeft)

		elseif UserInputService:IsKeyDown(Enum.KeyCode.W) then -- Foward 
			playAnimation(MovementAnimations.DashFront, Enum.AnimationPriority.Action4, 1.75)
			createBodyVelocity(0, -DASH_FORCE, DASH_DURATION)  -- create body velocity with a force in the negative z direction to simluate a dash fowards.
			dashEffect(MovementAnimations.DashFront)
		else -- Back (Default)
			playAnimation(MovementAnimations.DashBack, Enum.AnimationPriority.Action4, 1.75)
			createBodyVelocity(0, DASH_FORCE, DASH_DURATION)  -- create body velocity with a force in the negative z direction to simluate a dash backwards.
		end
		
	-- If they user presses left control, set their walkspeed to 22 if 16 and vice versa to create a running effect.
	elseif input.KeyCode == Enum.KeyCode.LeftControl then
		humanoid.WalkSpeed = if humanoid.WalkSpeed == 22 then 16 else 22
	end
end)
