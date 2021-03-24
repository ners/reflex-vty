{-|
  Description: A CPU usage indicator
-}
module Example.CPU where

import Control.Exception
import Control.Monad.Fix
import Control.Monad.IO.Class
import Data.Time
import Data.Word

import Reflex
import Reflex.Vty

-- | Each constructor represents a cpu statistic column as presented in @/proc/stat@
data CpuStat
   = CpuStat_User
   | CpuStat_Nice
   | CpuStat_System
   | CpuStat_Idle
   | CpuStat_Iowait
   | CpuStat_Irq
   | CpuStat_Softirq
   | CpuStat_Steal
   | CpuStat_Guest
   | CpuStat_GuestNice
   deriving (Show, Read, Eq, Ord, Enum, Bounded)

-- | Read @/proc/stat@
getCpuStat :: IO (Maybe (CpuStat -> Word64))
getCpuStat = do
  s <- readFile "/proc/stat"
  _ <- evaluate $ length s -- Make readFile strict
  pure $ do
    cpuSummaryLine : _ <- pure $ lines s
    [user, nice, system, idle, iowait, irq, softirq, steal, guest, guestNice] <- pure $ map read $ words $ drop 4 cpuSummaryLine
    pure $ \case
      CpuStat_User -> user
      CpuStat_Nice -> nice
      CpuStat_System -> system
      CpuStat_Idle -> idle
      CpuStat_Iowait -> iowait
      CpuStat_Irq -> irq
      CpuStat_Softirq -> softirq
      CpuStat_Steal -> steal
      CpuStat_Guest -> guest
      CpuStat_GuestNice -> guestNice

sumStats :: (CpuStat -> Word64) -> [CpuStat] -> Word64
sumStats get stats = sum $ get <$> stats

-- | user + nice + system + irq + softirq + steal
nonIdleStats :: [CpuStat]
nonIdleStats =
  [ CpuStat_User
  , CpuStat_Nice
  , CpuStat_System
  , CpuStat_Irq
  , CpuStat_Softirq
  , CpuStat_Steal
  ]

-- | idle + iowait
idleStats :: [CpuStat]
idleStats =
  [ CpuStat_Idle
  , CpuStat_Iowait
  ]

-- | Draws the cpu usage percent as a live-updating bar graph. The output should look like:
--
--
-- > ╔═══════ CPU Usage ══════╗
-- > ║                        ║
-- > ║                        ║
-- > ║                        ║
-- > ║                        ║
-- > ║                        ║
-- > ║                        ║
-- > ║████████████████████████║
-- > ║████████████████████████║
-- > ║████████████████████████║
-- > ║████████████████████████║
-- > ╚════════════════════════╝
--
cpuStats
  :: ( Reflex t
     , MonadFix m
     , MonadHold t m
     , MonadIO (Performable m)
     , MonadIO m
     , PerformEvent t m
     , PostBuild t m
     , TriggerEvent t m
     , HasDisplaySize t m
     , ImageWriter t m
     , MonadLayout t m
     , MonadFocus t m
     , MonadNodeId m
     , HasVtyWidgetCtx t m
     , HasVtyInput t m
     )
  => m ()
cpuStats = do
  tick <- tickLossy 0.25 =<< liftIO getCurrentTime
  cpuStat :: Event t (Word64, Word64) <- fmap (fmapMaybe id) $
    performEvent $ ffor tick $ \_ -> do
      get <- liftIO getCpuStat
      pure $ case get of
        Nothing -> Nothing
        Just get' -> Just (sumStats get' nonIdleStats, sumStats get' idleStats)
  active <- foldDyn cpuPercentStep ((0, 0), 0) cpuStat
  let pct = fmap snd active
  boxTitle (pure doubleBoxStyle) " CPU Usage " $ col $ do
    grout flex blank
    dh <- displayHeight
    let h :: Dynamic t Int = ceiling <$> ((*) <$> (fromIntegral <$> dh) <*> pct)
    tile (fixed h) $ fill '█'

-- | Determine the current percentage usage according to this algorithm:
--
-- PrevIdle = previdle + previowait
-- Idle = idle + iowait
-- 
-- PrevNonIdle = prevuser + prevnice + prevsystem + previrq + prevsoftirq + prevsteal
-- NonIdle = user + nice + system + irq + softirq + steal
-- 
-- PrevTotal = PrevIdle + PrevNonIdle
-- Total = Idle + NonIdle
-- 
-- totald = Total - PrevTotal
-- idled = Idle - PrevIdle
-- 
-- CPU_Percentage = (totald - idled)/totald
--
-- Source: https://stackoverflow.com/questions/23367857/accurate-calculation-of-cpu-usage-given-in-percentage-in-linux
cpuPercentStep
  :: (Word64, Word64) -- Current active, Current idle
  -> ((Word64, Word64), Double) -- (Previous idle, Previous total), previous percent
  -> ((Word64, Word64), Double) -- (New idle, new total), percent
cpuPercentStep (nonidle, idle) ((previdle, prevtotal), _) =
  let total = idle + nonidle
      idled = idle - previdle
      totald = total - prevtotal
  in ( (idle, total)
     , (fromIntegral $ totald - idled) / fromIntegral totald
     )
