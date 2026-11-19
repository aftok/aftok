-- | Handlers for the public (unauthenticated) tip-jar endpoints.
--
-- Both handlers are gated by the project's @tip_jar_enabled@ flag rather than by
-- a user session: the flag is the authorization for the otherwise-unauth reads.
-- The roster GET reports eligible participants; the POST derives a fresh Orchard
-- address per recipient and assembles a ZIP 321 payment request.
module Aftok.Servant.TipJar
  ( -- * API (re-exported from aftok-api)
    TipJarAPI,
    TipJarInfo (..),
    TipRequestBody (..),
    TipOutput (..),
    TipRequestResult (..),

    -- * Handlers
    tipJarInfoHandler,
    tipRequestHandler,
  )
where

import Aftok.API.TipJar
  ( TipJarAPI,
    TipJarInfo (..),
    TipOutput (..),
    TipRequestBody (..),
    TipRequestResult (..),
  )
import qualified Aftok.Currency.Zcash as Zcash
import Aftok.Currency.Zcash.Zip321 (PaymentItem (..), PaymentRequest (..))
import qualified Aftok.Currency.Zcash.Zip321 as Zip321
import Aftok.Database
  ( DBOp (ListProjectContributors, ReadWorkIndex),
    MonadDB,
    findContributorTipSettings,
    findProject,
    findProjectTipSettings,
    findUserZcashIVK,
    liftdb,
  )
import Aftok.Project
  ( Project,
    ProjectTipSettings,
    ctsMinZatoshi,
    ctsParticipate,
    ctsShowHandle,
    depRules,
    projectName,
    ptsEnabled,
    ptsMemoTemplate,
  )
import Aftok.Servant.App (AppM, envConfig, runDB)
import Aftok.ServerConfig (zcashConfig)
import Aftok.TimeLog
  ( WorkShares,
    creditToShares,
    payouts,
    toDepF,
    wsShare,
  )
import Aftok.TipJar (Candidate (..), allocate)
import Aftok.Types
  ( CreditTo (..),
    ProjectId,
    UserName (..),
  )
import Aftok.Util (fromMaybeT)
import Control.Lens ((^.))
import Control.Monad.Trans.Maybe (mapMaybeT)
import Crypto.Random.Types (getRandomBytes)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Thyme.Clock as C
import Lrzhs (deriveOrchardAddress)
import Lrzhs.Types (mkDiversifierIndex)
import Servant

-- | A resolved, eligible contributor: participating, with a stored,
-- Orchard-valid UIVK (validated at capture time in Phase 2a).
data TipCand = TipCand
  { tcHandle :: UserName,
    tcIvk :: Zcash.IVK,
    tcShow :: Bool,
    tcWeight :: Rational,
    tcThreshold :: Word64
  }

userNameText :: UserName -> Text
userNameText (UserName t) = t

-- | Resolve the eligible tip recipients from the current payout shares. Runs
-- without project authorization (the caller has already passed the
-- @tip_jar_enabled@ gate).
gatherCandidates :: (MonadDB m) => ProjectId -> WorkShares -> m [TipCand]
gatherCandidates pid shares = do
  contribs <- liftdb (ListProjectContributors pid)
  let handleOf = M.fromList [(u, h) | (u, h, _) <- contribs]
  fmap catMaybes . forM (M.toList (shares ^. creditToShares)) $ \(ct, ws) ->
    case ct of
      CreditToUser uid -> do
        mset <- findContributorTipSettings pid uid
        mivk <- findUserZcashIVK uid
        pure $ do
          s <- mset
          guard (s ^. ctsParticipate)
          ivk <- mivk
          h <- M.lookup uid handleOf
          pure (TipCand h ivk (s ^. ctsShowHandle) (ws ^. wsShare) (s ^. ctsMinZatoshi))
      _ -> pure Nothing

-- | 404 unless the project exists and its tip jar is enabled; returns the
-- project, its tip settings, and the currently-eligible recipients.
loadTipJar :: ProjectId -> AppM (Project, ProjectTipSettings, [TipCand])
loadTipJar pid = do
  msettings <- runDB $ findProjectTipSettings pid
  settings <- case msettings of
    Just s | s ^. ptsEnabled -> pure s
    _ -> throwError err404 {errBody = "Tip jar not available"}
  project <-
    fromMaybeT
      (throwError err404 {errBody = "Project not found"})
      (mapMaybeT runDB $ findProject pid)
  widx <- runDB $ liftdb (ReadWorkIndex pid)
  now <- liftIO C.getCurrentTime
  let shares = payouts (toDepF (project ^. depRules)) now widx
  cands <- runDB $ gatherCandidates pid shares
  pure (project, settings, cands)

-- | Public roster: project name, eligible-participant count, and the handles of
-- those who opted to show their handle.
tipJarInfoHandler :: ProjectId -> AppM TipJarInfo
tipJarInfoHandler pid = do
  (project, _settings, cands) <- loadTipJar pid
  pure $
    TipJarInfo
      { tjiProjectName = project ^. projectName,
        tjiParticipantCount = length cands,
        tjiNamedRecipients = [userNameText (tcHandle c) | c <- cands, tcShow c]
      }

-- | Public build-a-payment: splits the requested amount across eligible
-- recipients, derives a fresh Orchard address per recipient, and returns a ZIP
-- 321 URI (or 'TipTooSmall' if no recipient can meet its threshold).
tipRequestHandler :: ProjectId -> TipRequestBody -> AppM TipRequestResult
tipRequestHandler pid body = do
  let amount = trbAmountZatoshi body
  when (amount == 0) $
    throwError err400 {errBody = "amount must be positive"}
  env <- ask
  let net = Zcash.zcashNetwork (env ^. envConfig . zcashConfig)
  (project, settings, cands) <- loadTipJar pid
  let candList = [Candidate c (tcWeight c) (tcThreshold c) | c <- cands]
  if null cands
    then pure TipNoRecipients
    else case allocate candList amount of
      Left minV -> pure (TipTooSmall minV)
      Right outs -> do
        let memoText =
              fromMaybe
                ("Aftok tip: " <> project ^. projectName)
                (settings ^. ptsMemoTemplate)
            memo = if T.null memoText then Nothing else Just (mkMemo memoText)
        items <- forM outs $ \(cand, z) -> do
          idxBytes <- liftIO (getRandomBytes 11)
          let idx = fromMaybe (error "11 bytes is a valid diversifier index") (mkDiversifierIndex idxBytes)
          eaddr <- liftIO $ deriveOrchardAddress net (Zcash.ivkText (tcIvk cand)) idx
          case eaddr of
            Left _ ->
              throwError err500 {errBody = "internal error building the payment request"}
            Right ua ->
              pure
                ( PaymentItem
                    { _address = Zcash.Address ua,
                      _amount = Zcash.Zatoshi z,
                      _memo = memo,
                      _message = Nothing,
                      _label = Nothing,
                      _other = []
                    },
                  TipOutput ua z (if tcShow cand then Just (userNameText (tcHandle cand)) else Nothing)
                )
        case nonEmpty (map fst items) of
          Nothing -> throwError err500 {errBody = "no recipients after allocation"}
          Just paymentItems -> do
            let req = PaymentRequest paymentItems
                elided = length cands - length outs
            pure $ TipOk (Zip321.toURI req) amount (map snd items) elided

-- | Build a memo, capped at the 512-byte Zcash memo limit.
mkMemo :: Text -> Zcash.Memo
mkMemo t = Zcash.Memo (BS.take 512 (encodeUtf8 t))
