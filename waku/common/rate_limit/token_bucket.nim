{.push raises: [].}

import chronos, std/math, std/options

const BUDGET_COMPENSATION_LIMIT_PERCENT = 0.25

## This is an extract from chronos/rate_limit.nim due to the found bug in the original implementation.
## Unfortunately that bug cannot be solved without harm the original features of TokenBucket class.
## So, this current shortcut is used to enable move ahead with nwaku rate limiter implementation.
## ref: https://github.com/status-im/nim-chronos/issues/500
##
## This version of TokenBucket is different from the original one in chronos/rate_limit.nim in many ways:
## - It has a new mode called `Compensating` which is the default mode.
##   Compensation is calculated as the not used bucket capacity in the last measured period(s) in average.
##   or up until maximum the allowed compansation treshold (Currently it is const 25%).
##   Also compensation takes care of the proper time period calculation to avoid non-usage periods that can lead to
##   overcompensation.
## - Strict mode is also available which will only replenish when time period is over but also will fill
##   the bucket to the max capacity.

type
  ReplenishMode* = enum
    Strict
    Compensating

  TokenBucket* = ref object
    budget: int ## Current number of tokens in the bucket
    budgetCap: int ## Bucket capacity
    lastTimeFull: Moment
      ## This timer measures the proper periodizaiton of the bucket refilling
    fillDuration: Duration ## Refill period
    case replenishMode*: ReplenishMode
    of Strict:
      ## In strict mode, the bucket is refilled only till the budgetCap
      discard
    of Compensating:
      ## This is the default mode.
      maxCompensation: float

func periodDistance(bucket: TokenBucket, currentTime: Moment): float =
  ## notice fillDuration cannot be zero by design
  ## period distance is a float number representing the calculated period time
  ## since the last time bucket was refilled.
  return
    nanoseconds(currentTime - bucket.lastTimeFull).float /
    nanoseconds(bucket.fillDuration).float

func getUsageAverageSince(bucket: TokenBucket, distance: float): float =
  if distance == 0.float:
    ## in case there is zero time difference than the usage percentage is 100%
    return 1.0

  ## budgetCap can never be zero
  ## usage average is calculated as a percentage of total capacity available over
  ## the measured period
  return bucket.budget.float / bucket.budgetCap.float / distance

proc calcCompensation(bucket: TokenBucket, averageUsage: float): int =
  # if we already fully used or even overused the tokens, there is no place for compensation
  if averageUsage >= 1.0:
    return 0

  ## compensation is the not used bucket capacity in the last measured period(s) in average.
  ## or maximum the allowed compansation treshold
  let compensationPercent =
    min((1.0 - averageUsage) * bucket.budgetCap.float, bucket.maxCompensation)
  return trunc(compensationPercent).int

func periodElapsed(bucket: TokenBucket, currentTime: Moment): bool =
  return currentTime - bucket.lastTimeFull >= bucket.fillDuration

## Update will take place if bucket is empty and trying to consume tokens.
## It checks if the bucket can be replenished as refill duration is passed or not.
## - strict mode:
proc updateStrict(bucket: TokenBucket, currentTime: Moment) =
  if bucket.fillDuration == default(Duration):
    bucket.budget = min(bucket.budgetCap, bucket.budget)
    return

  if not periodElapsed(bucket, currentTime):
    return

  bucket.budget = bucket.budgetCap
  bucket.lastTimeFull = currentTime

## - compensating - ballancing load:
##    - between updates we calculate average load (current bucket capacity / number of periods till last update)
##      - gives the percentage load used recently
##    - with this we can replenish bucket up to 100% + calculated leftover from previous period (caped with max treshold)
proc updateWithCompensation(bucket: TokenBucket, currentTime: Moment) =
  if bucket.fillDuration == default(Duration):
    bucket.budget = min(bucket.budgetCap, bucket.budget)
    return

  # do not replenish within the same period
  if not periodElapsed(bucket, currentTime):
    return

  let distance = bucket.periodDistance(currentTime)
  let recentAvgUsage = bucket.getUsageAverageSince(distance)
  let compensation = bucket.calcCompensation(recentAvgUsage)

  bucket.budget = bucket.budgetCap + compensation
  bucket.lastTimeFull = currentTime

proc update(bucket: TokenBucket, currentTime: Moment) =
  if bucket.replenishMode == ReplenishMode.Compensating:
    updateWithCompensation(bucket, currentTime)
  else:
    updateStrict(bucket, currentTime)

proc getAvailableCapacity*(
    bucket: TokenBucket, currentTime: Moment = Moment.now()
): tuple[budget: int, budgetCap: int, lastTimeFull: Moment] =
  ## Returns the available capacity of the bucket: (budget, budgetCap)

  if periodElapsed(bucket, currentTime):
    case bucket.replenishMode
    of ReplenishMode.Strict:
      return (bucket.budgetCap, bucket.budgetCap, bucket.lastTimeFull)
    of ReplenishMode.Compensating:
      let distance = bucket.periodDistance(currentTime)
      let recentAvgUsage = bucket.getUsageAverageSince(distance)
      let compensation = bucket.calcCompensation(recentAvgUsage)
      let availableBudget = bucket.budgetCap + compensation
      return (availableBudget, bucket.budgetCap, bucket.lastTimeFull)
  return (bucket.budget, bucket.budgetCap, bucket.lastTimeFull)

proc tryConsume*(bucket: TokenBucket, tokens: int, now = Moment.now()): bool =
  ## If `tokens` are available, consume them,
  ## Otherwhise, return false.

  if bucket.budget >= bucket.budgetCap:
    bucket.lastTimeFull = now

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    return true

  bucket.update(now)

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    return true
  else:
    return false

proc replenish*(bucket: TokenBucket, tokens: int, now = Moment.now()) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.budget += tokens
  bucket.update(now)

proc new*(
    T: type[TokenBucket],
    budgetCap: int,
    fillDuration: Duration = 1.seconds,
    mode: ReplenishMode = ReplenishMode.Compensating,
    budget: int = -1, # -1 means "use budgetCap"
    lastTimeFull: Moment = Moment.now(),
): T =
  assert not isZero(fillDuration)
  assert budgetCap != 0
  assert lastTimeFull <= Moment.now()
  let actualBudget = if budget == -1: budgetCap else: budget
  assert actualBudget >= 0 and actualBudget <= budgetCap

  ## Create different mode TokenBucket
  case mode
  of ReplenishMode.Strict:
    return T(
      budget: actualBudget,
      budgetCap: budgetCap,
      fillDuration: fillDuration,
      lastTimeFull: lastTimeFull,
      replenishMode: mode,
    )
  of ReplenishMode.Compensating:
    T(
      budget: actualBudget,
      budgetCap: budgetCap,
      fillDuration: fillDuration,
      lastTimeFull: lastTimeFull,
      replenishMode: mode,
      maxCompensation: budgetCap.float * BUDGET_COMPENSATION_LIMIT_PERCENT,
    )

proc newStrict*(T: type[TokenBucket], capacity: int, period: Duration): TokenBucket =
  T.new(capacity, period, ReplenishMode.Strict)

proc newCompensating*(
    T: type[TokenBucket], capacity: int, period: Duration
): TokenBucket =
  T.new(capacity, period, ReplenishMode.Compensating)

func `$`*(b: TokenBucket): string {.inline.} =
  if isNil(b):
    return "nil"
  return $b.budgetCap & "/" & $b.fillDuration

func `$`*(ob: Option[TokenBucket]): string {.inline.} =
  if ob.isNone():
    return "no-limit"

  return $ob.get()
