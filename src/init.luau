--[=[
	@class DynamicTween
	
	DynamicTimer 기반 시간축을 따르며 Delay, 반복, 역재생, Instance 속성 매핑 등을 지원하는 범용 Tween 객체입니다.
	Heartbeat, RenderStepped, Post/PreSimulation 신호 또는 사용자 정의 StepEvent 위에서 원하는 값 타입을 선형 보간합니다.

	:::info
	일반적인 Tween 은 `DynamicTimer.GlobalTimer:CreateDynamicTween` 으로 공유 타이머를 활용하는 편이 안전합니다.
	:::
]=]

local RunService = game:GetService("RunService")

local LinearInterpolation = require("./roblox_packages/LinearInterpolation")
local Maid = require("./roblox_packages/Maid")
local MathUtil = require("./roblox_packages/MathUtil")
local Signal = require("./roblox_packages/Signal")

local easingsByStyleAndDirection = MathUtil.easingsByStyleAndDirection
local HISTORY_RETENTION_DURATION = 30

local DynamicTween = {}
DynamicTween.__index = DynamicTween
DynamicTween.__type = "DynamicTween"

--#region Types
type DynamicTimer = any

type PlaySnapshot = {
	Type: "Play" | "Pause",
	Time: number,
	LastProgress: number,
}

export type DynamicTween<Value = any> = setmetatable<{
	--[=[
		@prop DynamicTween.IsDestroyed boolean
		트윈이 Destroy 호출로 정리되었는지 여부입니다.
	]=]
	IsDestroyed: boolean,
	--[=[
		@prop DynamicTween.IsPlaying boolean
		현재 StepEvent 업데이트에 참여 중인지 여부입니다.
	]=]
	IsPlaying: boolean,
	--[=[
		@prop DynamicTween.IsFinished boolean
		종료 콜백이 호출되고 반복 주기가 모두 끝났는지 여부입니다.
	]=]
	IsFinished: boolean,

	--[=[
		@prop DynamicTween.Timer DynamicTimer
		연결된 DynamicTimer 입니다. TimeScale, 되감기 등이 반영됩니다.
	]=]
	Timer: DynamicTimer,
	--[=[
		@prop DynamicTween.Maid Maid
		내부 연결과 Signal 을 정리하기 위한 Maid 입니다.
	]=]
	Maid: Maid.Maid,

	--[=[
		@prop DynamicTween.CreationTime number
		트윈이 생성된 시점의 타이머 경과 시간(초)입니다.
	]=]
	CreationTime: number,
	--[=[
		@prop DynamicTween.ProgressTime number
		현재까지 누적된 진행 시간입니다. 반복, Delay 를 모두 포함합니다.
	]=]
	ProgressTime: number,
	--[=[
		@prop DynamicTween.Duration number
		한 사이클에 실제로 보간이 일어나는 시간(초)입니다.
	]=]
	Duration: number,
	--[=[
		@prop DynamicTween.EasingStyle MathUtil.EasingStyle
		MathUtil 에 정의된 이징 스타일입니다.
	]=]
	EasingStyle: MathUtil.EasingStyle,
	--[=[
		@prop DynamicTween.EasingDirection MathUtil.EasingDirection
		이징 방향(In, Out, InOut 등)입니다.
	]=]
	EasingDirection: MathUtil.EasingDirection,

	--[=[
		@prop DynamicTween.Callback (value: Value)->()? 
		보간된 값이 갱신될 때 호출되는 콜백입니다.
	]=]
	Callback: (value: Value) -> ()?,
	--[=[
		@prop DynamicTween.StepEvent StepEvent
		Heartbeat, RenderStepped, 사용자 정의 Signal 등 업데이트 이벤트입니다.
	]=]
	StepEvent: StepEvent,

	--[=[
		@prop DynamicTween.Start Value
		보간 시작 값입니다.
	]=]
	Start: Value,
	--[=[
		@prop DynamicTween.Goal Value
		보간 목표 값입니다.
	]=]
	Goal: Value,
	--[=[
		@prop DynamicTween.CurrentValue Value
		최근 콜백 호출 시 전달된 현재 값입니다.
	]=]
	CurrentValue: Value,

	--[=[
		@prop DynamicTween.RepeatCount number
		추가로 반복할 횟수입니다. -1 이면 무한 반복입니다.
	]=]
	RepeatCount: number,
	--[=[
		@prop DynamicTween.Reverses boolean
		true 면 왕복(역재생) 모드로 진행합니다.
	]=]
	Reverses: boolean,
	--[=[
		@prop DynamicTween.DelayTime number
		각 사이클 사이에 추가되는 대기 시간입니다.
	]=]
	DelayTime: number,

	--[=[
		@prop DynamicTween.Playing Signal.Signal<>
		Play 호출 시 발동되는 Signal 입니다.
	]=]
	Playing: Signal.Signal<>,
	--[=[
		@prop DynamicTween.Completed Signal.Signal<>
		모든 진행이 끝났을 때 발동되는 Signal 입니다.
	]=]
	Completed: Signal.Signal<>,

	_playSnapshots: { PlaySnapshot },
	_historyExpirationTime: number,
	_lastObservedElapsedTime: number,
}, typeof(DynamicTween)>

--[=[
	@type DynamicTween.StepEvent =
		"Heartbeat" | "RenderStepped" | "Stepped" | "PostSimulation" | "PreSimulation" | Signal.Signal | RBXScriptSignal
	@within DynamicTween
	StepEvent 는 트윈을 업데이트할 이벤트 소스 타입입니다.
	Signal 또는 Roblox 이벤트 객체도 사용할 수 있습니다.
]=]
type StepEvent =
	| "Heartbeat"
	| "RenderStepped"
	| "Stepped"
	| "PostSimulation"
	| "PreSimulation"
	| Signal.Signal
	| RBXScriptSignal
--#endregion Types

--#region Constructors
--[=[
	@interface DynamicTween.BaseDynamicTweenParams
	@within DynamicTween
	트윈 생성 시 공통으로 사용하는 선택 인자입니다.

	.Duration number? -- 기본값 1초. 하나의 이징 사이클 길이입니다.
	.EasingStyle MathUtil.EasingStyle? -- 기본 "Cubic".
	.EasingDirection MathUtil.EasingDirection? -- 기본 "InOut".
	.StepEvent StepEvent? -- 기본 "Heartbeat".
	.RepeatCount number? -- 기본 0. -1 을 넣으면 무한 반복.
	.Reverses boolean? -- true 면 반복마다 역재생합니다.
	.DelayTime number? -- 각 반복 사이에 추가 대기 시간을 부여합니다.
	.Timer DynamicTimer? -- 주입하지 않으면 GlobalTimer 를 사용합니다.
]=]
export type BaseDynamicTweenParams = {
	Duration: number?,
	EasingStyle: MathUtil.EasingStyle?,
	EasingDirection: MathUtil.EasingDirection?,

	StepEvent: StepEvent?,

	RepeatCount: number?,
	Reverses: boolean?,
	DelayTime: number?,

	Timer: DynamicTimer?,
}

--[=[
	@interface DynamicTween.DynamicTweenParams
	@within DynamicTween
	값 보간에 필요한 필수·선택 인자입니다.

	.Start Value? -- 명시하지 않으면 숫자 0.
	.Goal Value? -- 명시하지 않으면 숫자 1.
	.Callback (value: Value)->() -- 각 업데이트마다 호출되는 필수 콜백입니다.
	.Interpolation LinearInterpolation.Interpolation<Value>? -- 값 타입용 보간 함수. 기본적으로 타입에서 추론합니다.
]=]
export type DynamicTweenParams<Value = number> = {
	Start: Value?,
	Goal: Value?,

	Callback: (value: Value) -> (),
	Interpolation: LinearInterpolation.Interpolation<Value>?,
} & BaseDynamicTweenParams

--[=[
	@within DynamicTween
	@param params DynamicTweenParams<Value> -- 시작/목표 값, 콜백, 반복 옵션을 포함한 트윈 설정.
	@return DynamicTween<Value> -- 생성된 트윈 객체.
]=]
function DynamicTween.new<Value>(params: DynamicTweenParams<Value>): DynamicTween<Value>
	local self = setmetatable({}, DynamicTween)

	self.Timer = params.Timer
		-- 순환 참조를 피하기 위함
		or (require("./DynamicTimer") :: any).GlobalTimer
	self.Maid = Maid.new()

	self.IsDestroyed = false
	self.IsPlaying = false
	self.IsFinished = false

	self.CreationTime = self.Timer.ElapsedTime
	self.ProgressTime = 0

	self.Duration = params.Duration or 1
	self.EasingStyle = params.EasingStyle or "Cubic"
	self.EasingDirection = params.EasingDirection or "InOut"

	self.Start = params.Start or 0
	self.Goal = params.Goal or 1

	self.Callback = params.Callback or error("Missing Callback")
	self.StepEvent = params.StepEvent or "Heartbeat"

	self.Interpolation = params.Interpolation or LinearInterpolation.GetFunctionFromValueType(self.Start)

	self.RepeatCount = params.RepeatCount or 0
	self.Reverses = params.Reverses or false
	self.DelayTime = params.DelayTime or 0

	self.Playing = Signal.new()
	self._playSnapshots = {}
	self._historyExpirationTime = math.huge
	self._lastObservedElapsedTime = self.CreationTime

	self.Completed = Signal.new()
	self.Maid:GiveTask(self.Playing, self.Completed)

	self:_connectToTimer()

	return self
end

-- 시간 점프에 즉각 반응하기 위해 ElapsedTimeChanged에 연결합니다.
function DynamicTween:_connectToTimer()
	self.Maid:GiveTask(self.Timer.ElapsedTimeChanged:Connect(function(newTime)
		self:_onElapsedTimeChanged(newTime)
	end))
end

function DynamicTween:_onElapsedTimeChanged(newTime: number)
	if self.IsDestroyed then
		return
	end

	self._lastObservedElapsedTime = newTime

	if newTime < self.CreationTime then
		self:Destroy()
		return
	end

	if self.IsFinished and self._historyExpirationTime ~= math.huge and newTime >= self._historyExpirationTime then
		self:_clearPlaybackHistory()
		return
	end

	local snapshots = self._playSnapshots
	while #snapshots > 0 and snapshots[#snapshots].Time > newTime do
		table.remove(snapshots)
	end

	local newProgressTime = 0
	local newIsPlaying = false
	local lastPlaySnapshot: PlaySnapshot? = nil

	for _, snapshot in ipairs(snapshots) do
		if snapshot.Type == "Play" then
			lastPlaySnapshot = snapshot
			newProgressTime = snapshot.LastProgress
			newIsPlaying = true
		elseif snapshot.Type == "Pause" then
			newProgressTime = snapshot.LastProgress
			lastPlaySnapshot = nil
			newIsPlaying = false
		end
	end

	if lastPlaySnapshot then
		newProgressTime = lastPlaySnapshot.LastProgress + (newTime - lastPlaySnapshot.Time)
		newIsPlaying = true
	end

	local maxDuration = self:_getMaxDuration()
	newProgressTime = math.max(0, newProgressTime)

	if newProgressTime >= maxDuration then
		newProgressTime = maxDuration
		self.ProgressTime = newProgressTime

		if not self.IsFinished then
			self:_finish()
		else
			self.IsPlaying = false
		end
		return
	end

	if self.IsFinished then
		self.IsFinished = false
		self._historyExpirationTime = math.huge
	end

	self.ProgressTime = newProgressTime
	self.IsPlaying = newIsPlaying

	if not self.IsPlaying then
		return
	end

	self:_runCallback(self:_getProgress(newProgressTime))
end

--[=[
	@within DynamicTween
	@param timer DynamicTimer -- 사용할 타이머.
	@param params DynamicTweenParams<Value> -- 트윈 설정.
	@return DynamicTween<Value> -- 지정된 타이머와 연결된 트윈.
]=]
function DynamicTween.fromTimer<Value>(timer: DynamicTimer, params: DynamicTweenParams<Value>): DynamicTween<Value>
	params.Timer = timer
	return DynamicTween.new(params)
end

--[=[
	@type DynamicTween.DynamicTweenFromInstance = DynamicTween<number> & { Instance: Instance }
	@within DynamicTween
	Instance Property 트윈을 위해 Instance 참조를 추가로 보관합니다.
]=]
export type DynamicTweenFromInstance = {
	Instance: Instance,
} & DynamicTween<number>

--[=[
	@within DynamicTween
	@param instance Instance -- 속성을 변경할 대상 Instance.
	@param params BaseDynamicTweenParams -- 시간 관련 공통 옵션.
	@param propertyMap {[string]: any} -- 속성명과 목표 값 쌍.
	@return DynamicTween.DynamicTweenFromInstance -- Instance 갱신용 트윈.
]=]
function DynamicTween.fromInstance(
	instance: Instance,
	params: BaseDynamicTweenParams,
	propertyMap: { [string]: any }
): DynamicTweenFromInstance
	local interpolations = {}
	local i = 0
	for property, goalValue in propertyMap do
		i += 1

		local initialValue = instance[property]
		local lerp = LinearInterpolation.GetFunctionFromValueType(initialValue)

		interpolations[i] = function(alpha)
			instance[property] = lerp(initialValue, goalValue, alpha)
		end
	end

	local self = DynamicTween.new({
		Start = 0,
		Goal = 1,
		Duration = params.Duration,

		Callback = function(alpha)
			for _, interpolation in ipairs(interpolations) do
				interpolation(alpha)
			end
		end,
		EasingStyle = params.EasingStyle,
		EasingDirection = params.EasingDirection,

		StepEvent = params.StepEvent,
		RepeatCount = params.RepeatCount,
		Reverses = params.Reverses,
		DelayTime = params.DelayTime,

		Timer = params.Timer,
	})

	self.Instance = instance

	return self
end

--#endregion Constructors
--#region Methods
--[=[
	@within DynamicTween
	트윈을 파괴하고 내부 Signal 및 연결을 정리합니다.
]=]
function DynamicTween:Destroy()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.IsPlaying = false
	self.Maid:Destroy()

	table.freeze(self :: any)
end

--[=[
	@within DynamicTween
	진행 시간을 유지한 채 트윈을 재생합니다.
	되감기가 발생했으면 Timer 기록을 기반으로 ProgressTime 을 다시 맞춥니다.
]=]
function DynamicTween:Play()
	if self.IsPlaying then
		warn(`DynamicTween "{self}" is playing already.`)
		return
	end

	if self.IsDestroyed then
		warn(`DynamicTween "{self}" is destroyed.`)
		return
	end

	if self.IsFinished then
		warn(`DynamicTween "{self}" is Finished.`)
		return
	end

	self._historyExpirationTime = math.huge
	self.IsPlaying = true
	table.insert(self._playSnapshots, {
		Type = "Play",
		Time = self.Timer.ElapsedTime,
		LastProgress = self.ProgressTime,
	})

	self.Playing:Fire()
	self:_updateUntilNotPlaying()
end

function DynamicTween:_updateUntilNotPlaying()
	local stepEvent = self.StepEvent

	local event = if typeof(stepEvent) == "string" then RunService[stepEvent] else stepEvent

	local connection
	connection = event:Connect(function()
		if not self.IsPlaying then
			connection:Disconnect()
			return
		end

		local currentTime = self.Timer:GetElapsedTime()
		local dt = currentTime - self._lastObservedElapsedTime

		self._lastObservedElapsedTime = currentTime

		self:_update(dt)
	end)
end

--[=[
	@within DynamicTween
	현재 ProgressTime 을 유지한 채 트윈을 일시정지합니다.
	`Play` 를 다시 호출하면 해당 지점부터 이어집니다.
]=]
function DynamicTween:Pause()
	if not self.IsPlaying then
		return
	end
	table.insert(self._playSnapshots, {
		Type = "Pause",
		Time = self.Timer.ElapsedTime,
		LastProgress = self.ProgressTime,
	})

	self.IsPlaying = false
end

function DynamicTween:_update(dt)
	local maxDuration = self:_getMaxDuration()
	local currentTweenTime = self.ProgressTime + dt

	if currentTweenTime >= maxDuration then
		self.ProgressTime = maxDuration
		self:_finish()
		return
	end

	self.ProgressTime = currentTweenTime
	self:_runCallback(self:_getProgress(currentTweenTime))
end

function DynamicTween:_getMaxDuration(): number
	if self.RepeatCount < 0 then
		return math.huge
	end

	local totalRepeats = self.RepeatCount + 1
	local cycleDuration = self.Duration + self.DelayTime

	local maxDuration = cycleDuration * totalRepeats - self.DelayTime
	if self.Reverses then
		maxDuration = (cycleDuration * 2) * totalRepeats - self.DelayTime
	end

	return maxDuration
end

function DynamicTween:_getProgress(progressTime: number): number
	local easing = easingsByStyleAndDirection[self.EasingStyle][self.EasingDirection]
	local progress

	local duration = self.Duration
	local delayTime = self.DelayTime

	if not self.Reverses then
		local cycleDuration = duration + delayTime
		local cycleProgressTime = progressTime % cycleDuration
		progress = if cycleProgressTime < duration then cycleProgressTime / duration else 1
	else
		local cycleDuration = (duration + delayTime) * 2
		local cycleProgressTime = progressTime % cycleDuration

		if cycleProgressTime < duration then
			progress = cycleProgressTime / duration
		elseif cycleProgressTime < duration + delayTime then
			progress = 1
		elseif cycleProgressTime < duration * 2 + delayTime then
			progress = 1 - (cycleProgressTime - (duration + delayTime)) / duration
		else
			progress = 0
		end
	end

	return easing(progress)
end

function DynamicTween:_runCallback(progress)
	local value = self.Interpolation(self.Start, self.Goal, progress)
	self.CurrentValue = value
	task.spawn(self.Callback, value)
end

function DynamicTween:_clearPlaybackHistory()
	table.clear(self._playSnapshots)
	self.ProgressTime = 0
	self.IsPlaying = false
	self.IsFinished = true
	self._historyExpirationTime = math.huge
end

function DynamicTween:_finish()
	if self.IsFinished then
		return
	end

	self.IsFinished = true

	local finalProgress
	if not self.Reverses then
		finalProgress = 1
	else
		-- (RepeatCount + 1)이 짝수이면 정방향으로 끝나고, 홀수이면 역방향으로 끝납니다.
		finalProgress = (self.RepeatCount + 1) % 2 == 1 and 1 or 0
	end
	self:_runCallback(finalProgress)

	self.IsPlaying = false
	self:_complete()
	self._historyExpirationTime = self.Timer.ElapsedTime + HISTORY_RETENTION_DURATION
end

function DynamicTween:_complete()
	self.Completed:Fire()
end
--#endregion Methods

return DynamicTween
