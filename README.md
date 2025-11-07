Reretarget (SuperWoW + GUID Integration - Hunter Only)
IMPROVEMENT: UNIT_CASTEVENT-based Feign Death detection
- ONLY tracks Hunters (Rogues removed - retarget makes no sense for Vanish)
- Instant detection: Cast event = Feign Death, No cast = Real death
- NO MORE TIMERS - instant reaction!
- FIXED: Race condition when Hunter re-casts FD immediately after standing up
- FIXED: Target check for FD when selecting dead Hunter
- FIXED: Memory leak in lastDeathWasFD table
