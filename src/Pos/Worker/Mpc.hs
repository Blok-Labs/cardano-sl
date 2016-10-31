-- | MPC processing related workers.

module Pos.Worker.Mpc
       ( mpcOnNewSlot
       , mpcWorkers
       ) where

import           Control.Lens              (at, view)
import           Control.TimeWarp.Logging  (logDebug)
import           Control.TimeWarp.Logging  (logWarning)
import           Control.TimeWarp.Timed    (Microsecond, repeatForever, sec)
import qualified Data.HashMap.Strict       as HM (toList)
import           Formatting                (build, ords, sformat, (%))
import           Serokell.Util.Exceptions  ()
import           Universum

import           Pos.Communication.Methods (announceCommitment, announceOpening,
                                            announceShares, announceVssCertificate)
import           Pos.Communication.Types   (SendCommitment (..), SendOpening (..),
                                            SendShares (..))
import           Pos.Constants             (k)
import           Pos.DHT                   (sendToNeighbors)
import           Pos.State                 (generateNewSecret, getGlobalMpcData,
                                            getLocalMpcData, getOurCommitment,
                                            getOurOpening, getOurShares, getSecret)
import           Pos.Types                 (MpcData (..), SlotId (..), isCommitmentIdx,
                                            isOpeningIdx, isSharesIdx, mdCommitments,
                                            mdOpenings, mdShares)
import           Pos.WorkMode              (WorkMode, getNodeContext, ncPublicKey,
                                            ncSecretKey, ncVssKeyPair)

-- | Action which should be done when new slot starts.
mpcOnNewSlot :: WorkMode m => SlotId -> m ()
mpcOnNewSlot SlotId {..} = do
    ourPk <- ncPublicKey <$> getNodeContext
    ourSk <- ncSecretKey <$> getNodeContext
    -- TODO: should we randomise sending times to avoid the situation when
    -- the network becomes overwhelmed with everyone's messages?

    -- If we haven't yet, generate a new commitment and opening for MPC; send
    -- the commitment.
    shouldCreateCommitment <- do
        secret <- getSecret
        return $ isCommitmentIdx siSlot && isNothing secret
    when shouldCreateCommitment $ do
        logDebug $ sformat ("Generating secret for "%ords%" epoch") siEpoch
        (comm, _) <- generateNewSecret ourSk siEpoch
        logDebug $ sformat ("Generated secret for "%ords%" epoch") siEpoch
    shouldSendCommitment <- do
        commitmentInBlockchain <-
            isJust . view (mdCommitments . at ourPk) <$> getGlobalMpcData
        return $ isCommitmentIdx siSlot && not commitmentInBlockchain
    when shouldSendCommitment $ do
        mbComm <- getOurCommitment
        whenJust mbComm $ \comm -> do
            void . sendToNeighbors $ SendCommitment ourPk comm
            logDebug "Sent commitment to neighbors"
    -- Send the opening
    shouldSendOpening <- do
        openingInBlockchain <-
            isJust . view (mdOpenings . at ourPk) <$> getGlobalMpcData
        return $ isOpeningIdx siSlot && not openingInBlockchain
    when shouldSendOpening $ do
        mbOpen <- getOurOpening
        whenJust mbOpen $ \open -> do
            void . sendToNeighbors $ SendOpening ourPk open
            logDebug "Sent opening to neighbors"
    -- Send decrypted shares that others have sent us
    shouldSendShares <- do
        -- TODO: here we assume that all shares are always sent as a whole
        -- package.
        sharesInBlockchain <-
            isJust . view (mdShares . at ourPk) <$> getGlobalMpcData
        return $ isSharesIdx siSlot && not sharesInBlockchain
    when shouldSendShares $ do
        ourVss <- ncVssKeyPair <$> getNodeContext
        shares <- getOurShares ourVss
        unless (null shares) $ do
            void . sendToNeighbors $ SendShares ourPk shares
            logDebug "Sent shares to neighbors"

-- | All workers specific to MPC processing.
-- Exceptions:
-- 1. Worker which ticks when new slot starts.
mpcWorkers :: WorkMode m => [m ()]
mpcWorkers = [mpcTransmitter]

mpcTransmitterInterval :: Microsecond
mpcTransmitterInterval = sec 2

mpcTransmitter :: WorkMode m => m ()
mpcTransmitter =
    repeatForever mpcTransmitterInterval onError $
    do MpcData{..} <- getLocalMpcData
       mapM_ (uncurry announceCommitment) $ HM.toList _mdCommitments
       mapM_ (uncurry announceOpening) $ HM.toList _mdOpenings
       mapM_ (uncurry announceShares) $ HM.toList _mdShares
       mapM_ (uncurry announceVssCertificate) $ HM.toList _mdVssCertificates
  where
    onError e =
        mpcTransmitterInterval <$
        logWarning (sformat ("Error occured in mpcTransmitter: "%build) e)

