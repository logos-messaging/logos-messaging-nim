#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import testutils/unittests
import chronos
import ../../waku/common/rate_limit/token_bucket

suite "Token Bucket":
  test "TokenBucket Sync test - strict":
    var bucket = TokenBucket.newStrict(1000, 1.milliseconds)
    let
      start = Moment.now()
      fullTime = start + 1.milliseconds
    check:
      bucket.tryConsume(800, start) == true
      bucket.tryConsume(200, start) == true
      # Out of budget
      bucket.tryConsume(100, start) == false
      bucket.tryConsume(800, fullTime) == true
      bucket.tryConsume(200, fullTime) == true
      # Out of budget
      bucket.tryConsume(100, fullTime) == false

  test "TokenBucket Sync test - compensating":
    var bucket = TokenBucket.new(1000, 1.milliseconds)
    let
      start = Moment.now()
      fullTime = start + 1.milliseconds
    check:
      bucket.tryConsume(800, start) == true
      bucket.tryConsume(200, start) == true
      # Out of budget
      bucket.tryConsume(100, start) == false
      bucket.tryConsume(800, fullTime) == true
      bucket.tryConsume(200, fullTime) == true
      # Due not using the bucket for a full period the compensation will satisfy this request
      bucket.tryConsume(100, fullTime) == true

  test "TokenBucket Max compensation":
    var bucket = TokenBucket.new(1000, 1.minutes)
    var reqTime = Moment.now()

    check bucket.tryConsume(1000, reqTime)
    check bucket.tryConsume(1, reqTime) == false
    reqTime += 1.minutes
    check bucket.tryConsume(500, reqTime) == true
    reqTime += 1.minutes
    check bucket.tryConsume(1000, reqTime) == true
    reqTime += 10.seconds
    # max compensation is 25% so try to consume 250 more
    check bucket.tryConsume(250, reqTime) == true
    reqTime += 49.seconds
    # out of budget within the same period
    check bucket.tryConsume(1, reqTime) == false

  test "TokenBucket Short replenish":
    var bucket = TokenBucket.new(15000, 1.milliseconds)
    let start = Moment.now()
    check bucket.tryConsume(15000, start)
    check bucket.tryConsume(1, start) == false

    check bucket.tryConsume(15000, start + 1.milliseconds) == true

  test "TokenBucket getAvailableCapacity strict":
    let now = Moment.now()
    var reqTime = now
    var bucket =
      TokenBucket.new(1000, 1.minutes, ReplenishMode.Strict, lastTimeFull = now)

    # Test full bucket capacity ratio
    let lastTimeFull_1 = reqTime
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000, lastTimeFull_1)

    # # Consume some tokens and check ratio
    reqTime += 1.seconds
    let lastTimeFull_2 = reqTime

    check bucket.tryConsume(400, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (600, 1000, lastTimeFull_2)

    # Consume more tokens
    reqTime += 1.seconds
    check bucket.tryConsume(300, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (300, 1000, lastTimeFull_2)

    # Test when period has elapsed (should return   1.0)
    reqTime += 1.minutes
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000, lastTimeFull_2)

    let lastTimeFull_3 = reqTime
    # Test with empty bucket
    check bucket.tryConsume(1000, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (0, 1000, lastTimeFull_3)

  test "TokenBucket getAvailableCapacity compensating":
    let now = Moment.now()
    var reqTime = now
    var bucket =
      TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating, lastTimeFull = now)

    let lastTimeFull_1 = reqTime

    # Test full bucket capacity
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000, lastTimeFull_1)

    # Consume some tokens and check available capacity
    reqTime += 1.seconds
    let lastTimeFull_2 = reqTime
    check bucket.tryConsume(400, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (600, 1000, lastTimeFull_2)

    # Consume more tokens
    reqTime += 1.seconds
    check bucket.tryConsume(300, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (300, 1000, lastTimeFull_2)

    # Test compensation when period has elapsed - should get compensation for unused capacity
    # We used 700 tokens out of 1000 in 2 periods, so average usage was 35% per period
    # Compensation should be added for the unused 65% capacity (up to 25% max)
    reqTime += 1.minutes
    let (availableBudget, maxCap, _) = bucket.getAvailableCapacity(reqTime)
    check maxCap == 1000
    check availableBudget >= 1000 # Should have compensation
    check availableBudget <= 1250 # But limited to 25% max compensation

    # Test with minimal usage - less consumption means less compensation
    bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating)
    reqTime = Moment.now()
    check bucket.tryConsume(50, reqTime) == true
      # Use only 5% of capacity (950 remaining)

    # Move to next period - compensation based on remaining budget
    # UsageAverage = 950/1000/1.0 = 0.95, so compensation = (1.0-0.95)*1000 = 50
    reqTime += 1.minutes
    let (compensatedBudget, _, _) = bucket.getAvailableCapacity(reqTime)
    check compensatedBudget == 1050 # 1000 + 50 compensation

    # Test with full usage - maximum compensation due to zero remaining budget
    bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating)
    reqTime = Moment.now()
    check bucket.tryConsume(1000, reqTime) == true # Use full capacity (0 remaining)

    # Move to next period - maximum compensation since usage average is 0
    # UsageAverage = 0/1000/1.0 = 0.0, so compensation = (1.0-0.0)*1000 = 1000, capped at 250
    reqTime += 1.minutes
    let (maxCompensationBudget, _, _) = bucket.getAvailableCapacity(reqTime)
    check maxCompensationBudget == 1250 # 1000 + 250 max compensation

  test "TokenBucket custom budget parameter":
    let now = Moment.now()

    # Test with default budget (-1, should use budgetCap)
    var bucket1 = TokenBucket.new(1000, 1.seconds, budget = -1)
    let (budget1, budgetCap1, _) = bucket1.getAvailableCapacity(now)
    check budget1 == 1000
    check budgetCap1 == 1000

    # Test with custom budget less than capacity
    var bucket2 = TokenBucket.new(1000, 1.seconds, budget = 500)
    let (budget2, budgetCap2, _) = bucket2.getAvailableCapacity(now)
    check budget2 == 500
    check budgetCap2 == 1000

    # Test with budget equal to capacity
    var bucket3 = TokenBucket.new(1000, 1.seconds, budget = 1000)
    let (budget3, budgetCap3, _) = bucket3.getAvailableCapacity(now)
    check budget3 == 1000
    check budgetCap3 == 1000

    # Test with zero budget
    var bucket4 = TokenBucket.new(1000, 1.seconds, budget = 0)
    let (budget4, budgetCap4, _) = bucket4.getAvailableCapacity(now)
    check budget4 == 0
    check budgetCap4 == 1000

    # Test consumption with custom budget
    check bucket2.tryConsume(300, now) == true
    let (budget2After, budgetCap2After, _) = bucket2.getAvailableCapacity(now)
    check budget2After == 200
    check budgetCap2After == 1000
    check bucket2.tryConsume(300, now) == false # Should fail, only 200 remaining

  test "TokenBucket custom lastTimeFull parameter":
    let now = Moment.now()
    let pastTime = now - 5.seconds

    # Test with past lastTimeFull (bucket should be ready for refill)
    var bucket1 = TokenBucket.new(1000, 1.seconds, budget = 0, lastTimeFull = pastTime)
    # Since 5 seconds have passed and period is 1 second, bucket should refill
    check bucket1.tryConsume(1000, now) == true

    # Test with current time as lastTimeFull
    var bucket2 = TokenBucket.new(1000, 1.seconds, budget = 500, lastTimeFull = now)
    check bucket2.getAvailableCapacity(now) == (500, 1000, now)

    # Test strict mode with past lastTimeFull
    var bucket3 = TokenBucket.new(
      1000, 1.seconds, ReplenishMode.Strict, budget = 0, lastTimeFull = pastTime
    )
    check bucket3.tryConsume(1000, now) == true # Should refill to full capacity

    # Test compensating mode with past lastTimeFull and partial usage
    var bucket4 = TokenBucket.new(
      1000, 2.seconds, ReplenishMode.Compensating, budget = 300, lastTimeFull = pastTime
    )
    # 5 seconds passed, period is 2 seconds, so 2.5 periods elapsed
    # Usage average = 300/1000/2.5 = 0.12 (12% usage)
    # Compensation = (1.0 - 0.12) * 1000 = 880, capped at 250
    let (availableBudget, _, _) = bucket4.getAvailableCapacity(now)
    check availableBudget == 1250 # 1000 + 250 max compensation

  test "TokenBucket parameter combinations":
    let now = Moment.now()
    let pastTime = now - 3.seconds

    # Test strict mode with custom budget and past time
    var strictBucket = TokenBucket.new(
      budgetCap = 500,
      fillDuration = 1.seconds,
      mode = ReplenishMode.Strict,
      budget = 100,
      lastTimeFull = pastTime,
    )
    check strictBucket.getAvailableCapacity(now) == (500, 500, pastTime)
      # Should show full capacity since period elapsed

    # Test compensating mode with custom budget and past time
    var compBucket = TokenBucket.new(
      budgetCap = 1000,
      fillDuration = 2.seconds,
      mode = ReplenishMode.Compensating,
      budget = 200,
      lastTimeFull = pastTime,
    )
    # 3 seconds passed, period is 2 seconds, so 1.5 periods elapsed
    # Usage average = 200/1000/1.5 = 0.133 (13.3% usage)
    # Compensation = (1.0 - 0.133) * 1000 = 867, capped at 250
    let (compensatedBudget, _, _) = compBucket.getAvailableCapacity(now)
    check compensatedBudget == 1250 # 1000 + 250 max compensation

    # Test edge case: zero budget with immediate consumption
    var zeroBucket = TokenBucket.new(100, 1.seconds, budget = 0, lastTimeFull = now)
    check zeroBucket.tryConsume(1, now) == false # Should fail immediately
    check zeroBucket.tryConsume(1, now + 1.seconds) == true # Should succeed after period
