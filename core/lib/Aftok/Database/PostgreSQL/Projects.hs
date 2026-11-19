{-# LANGUAGE QuasiQuotes #-}

module Aftok.Database.PostgreSQL.Projects
  ( createProject,
    listProjects,
    findProject,
    findUserProjects,
    addUserToProject,
    createInvitation,
    findInvitation,
    acceptInvitation,
    listProjectContributors,
    findProjectTipSettings,
    setProjectTipSettings,
    findContributorTipSettings,
    setContributorTipSettings,
  )
where

import Aftok.Database
  ( DBError (..),
    InvitedUID,
    InvitingUID,
  )
import Aftok.Database.PostgreSQL.Types
  ( DBM,
    SerDepFunction (..),
    idParser,
    pexec,
    pquery,
    ptransact,
    utcParser,
  )
import Aftok.Project
  ( ContributorTipSettings (..),
    Invitation (..),
    InvitationCode,
    Project (..),
    ProjectTipSettings (..),
    depRules,
    inceptionDate,
    initiator,
    projectName,
    randomInvCode,
    renderInvCode,
  )
import Aftok.Types
  ( DepreciationRules (..),
    Email (..),
    ProjectId (..),
    UserId (..),
    UserName (..),
    depf,
    _ProjectId,
    _UserId,
  )
import Control.Exception (throwIO, try)
import Control.Lens
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (toJSON)
import qualified Data.Thyme.Time as C
import Data.UUID (UUID)
import Database.PostgreSQL.Simple (Only (..), SqlError (..), query)
import Database.PostgreSQL.Simple.FromField (fromJSONField)
import Database.PostgreSQL.Simple.FromRow (RowParser, field, fieldWith)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Safe (headMay)
import Prelude hiding (null)

projectParser :: RowParser Project
projectParser =
  Project
    <$> field
    <*> utcParser
    <*> idParser UserId
    <*> ( DepreciationRules
            <$> (unSerDepFunction <$> fieldWith fromJSONField)
            <*> (fmap C.toThyme <$> field)
        )

invitationParser :: RowParser Invitation
invitationParser =
  Invitation
    <$> idParser ProjectId
    <*> idParser UserId
    <*> fmap Email field
    <*> utcParser
    <*> fmap (fmap C.toThyme) field

createProject :: Project -> DBM ProjectId
createProject p = do
  conn <- asks snd
  result <-
    lift . lift $
      ( try $
          query
            conn
            [sql| INSERT INTO projects (project_name, inception_date, initiator_id, depreciation_fn)
          VALUES (?, ?, ?, ?) RETURNING id |]
            ( p ^. projectName,
              p ^. (inceptionDate . to C.fromThyme),
              p ^. (initiator . _UserId),
              toJSON $ p ^. depRules . depf . to SerDepFunction
            ) ::
          IO (Either SqlError [Only UUID])
      )
  case result of
    Left e
      | sqlState e == "23505" ->
          lift $ throwE $ DuplicateRecord "A project with this name already exists for this user"
      | otherwise ->
          lift . lift $ throwIO e
    Right (Only x : _) -> pure $ ProjectId x
    Right [] -> lift $ throwE SubjectNotFound

listProjects :: DBM [ProjectId]
listProjects =
  pquery (idParser ProjectId) [sql| SELECT id FROM projects |] ()

findProject :: ProjectId -> DBM (Maybe Project)
findProject (ProjectId pid) =
  headMay
    <$> pquery
      projectParser
      [sql| SELECT project_name, inception_date, initiator_id, depreciation_fn, first_revenue_date
            FROM projects WHERE id = ? |]
      (Only pid)

findUserProjects :: UserId -> DBM [(ProjectId, Project)]
findUserProjects (UserId uid) =
  pquery
    ((,) <$> idParser ProjectId <*> projectParser)
    [sql| SELECT DISTINCT ON (p.inception_date, p.id)
          p.id, p.project_name, p.inception_date, p.initiator_id, p.depreciation_fn, p.first_revenue_date
          FROM projects p LEFT OUTER JOIN project_companions pc ON pc.project_id = p.id
          WHERE pc.user_id = ?
          OR p.initiator_id = ?
          ORDER BY p.inception_date, p.id |]
    (uid, uid)

addUserToProject :: ProjectId -> InvitingUID -> InvitedUID -> DBM ()
addUserToProject pid current new =
  void $
    pexec
      [sql| INSERT INTO project_companions (project_id, user_id, invited_by) VALUES (?, ?, ?) |]
      (pid ^. _ProjectId, new ^. _UserId, current ^. _UserId)

createInvitation :: ProjectId -> InvitingUID -> Email -> C.UTCTime -> DBM InvitationCode
createInvitation (ProjectId pid) (UserId uid) (Email e) t = do
  invCode <- liftIO randomInvCode
  void $
    pexec
      [sql| INSERT INTO invitations (project_id, invitor_id, invitee_email, invitation_key, invitation_time)
          VALUES (?, ?, ?, ?, ?) |]
      (pid, uid, e, renderInvCode invCode, C.fromThyme t)
  pure invCode

findInvitation :: InvitationCode -> DBM (Maybe Invitation)
findInvitation ic =
  headMay
    <$> pquery
      invitationParser
      [sql| SELECT project_id, invitor_id, invitee_email, invitation_time, acceptance_time
        FROM invitations WHERE invitation_key = ? |]
      (Only $ renderInvCode ic)

acceptInvitation :: UserId -> InvitationCode -> C.UTCTime -> DBM ()
acceptInvitation (UserId uid) ic t = ptransact $ do
  void $
    pexec
      [sql| UPDATE invitations SET acceptance_time = ? WHERE invitation_key = ? |]
      (C.fromThyme t, renderInvCode ic)
  void $
    pexec
      [sql| INSERT INTO project_companions (project_id, user_id, invited_by, joined_at)
          SELECT i.project_id, ?, i.invitor_id, ?
          FROM invitations i
          WHERE i.invitation_key = ? |]
      (uid, C.fromThyme t, renderInvCode ic)

contributorParser :: RowParser (UserId, UserName, C.UTCTime)
contributorParser =
  (,,) <$> idParser UserId <*> (UserName <$> field) <*> utcParser

listProjectContributors :: ProjectId -> DBM [(UserId, UserName, C.UTCTime)]
listProjectContributors pid =
  pquery
    contributorParser
    [sql|
      SELECT DISTINCT u.id, u.handle, p.joined_at
      FROM users u
      JOIN project_companions p ON u.id = p.user_id
      WHERE p.project_id = ?
      ORDER BY p.joined_at
    |]
    (Only $ pid ^. _ProjectId)

findProjectTipSettings :: ProjectId -> DBM (Maybe ProjectTipSettings)
findProjectTipSettings pid =
  fmap (uncurry ProjectTipSettings) . headMay
    <$> pquery
      ((,) <$> field <*> field)
      [sql| SELECT tip_jar_enabled, tip_jar_memo_template FROM projects WHERE id = ? |]
      (Only $ pid ^. _ProjectId)

setProjectTipSettings :: ProjectId -> ProjectTipSettings -> DBM ()
setProjectTipSettings pid (ProjectTipSettings enabled memoT) =
  void $
    pexec
      [sql| UPDATE projects SET tip_jar_enabled = ?, tip_jar_memo_template = ? WHERE id = ? |]
      (enabled, memoT, pid ^. _ProjectId)

findContributorTipSettings :: ProjectId -> UserId -> DBM (Maybe ContributorTipSettings)
findContributorTipSettings pid uid =
  fmap (\(p, m, s) -> ContributorTipSettings p (fromIntegral (m :: Int64)) s) . headMay
    <$> pquery
      ((,,) <$> field <*> field <*> field)
      [sql| SELECT tip_participate, tip_min_zatoshi, tip_show_handle
            FROM project_companions WHERE project_id = ? AND user_id = ? |]
      (pid ^. _ProjectId, uid ^. _UserId)

setContributorTipSettings :: ProjectId -> UserId -> ContributorTipSettings -> DBM ()
setContributorTipSettings pid uid (ContributorTipSettings p m s) =
  void $
    pexec
      [sql| UPDATE project_companions
            SET tip_participate = ?, tip_min_zatoshi = ?, tip_show_handle = ?
            WHERE project_id = ? AND user_id = ? |]
      (p, fromIntegral m :: Int64, s, pid ^. _ProjectId, uid ^. _UserId)
