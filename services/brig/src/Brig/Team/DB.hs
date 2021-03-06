{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}

module Brig.Team.DB
    ( module T
    , insertInvitation
    , deleteInvitation
    , lookupInvitation
    , lookupInvitationCode
    , lookupInvitations
    , lookupInvitationByCode
    , lookupInvitationInfo

    , mkInvitationCode
    , mkInvitationId

    , InvitationInfo (..)
    ) where

import Brig.Data.Instances ()
import Brig.Data.Types as T
import Brig.Types.Common
import Brig.Types.User
import Brig.Types.Team.Invitation
import Cassandra
import Control.Lens
import Control.Monad.IO.Class
import Data.Id
import Data.Int
import Data.Range
import Data.UUID.V4
import Data.Text.Ascii (encodeBase64Url)
import Data.Time.Clock
import OpenSSL.Random (randBytes)

mkInvitationCode :: IO InvitationCode
mkInvitationCode = InvitationCode . encodeBase64Url <$> randBytes 24

mkInvitationId :: IO InvitationId
mkInvitationId = Id <$> nextRandom

data InvitationInfo = InvitationInfo
    { iiCode    :: InvitationCode
    , iiTeam    :: TeamId
    , iiInvId   :: InvitationId
    } deriving (Eq, Show)

insertInvitation :: MonadClient m => TeamId -> Email -> UTCTime -> m (Invitation, InvitationCode)
insertInvitation t email now = do
    iid  <- liftIO mkInvitationId
    code <- liftIO mkInvitationCode
    let inv = Invitation t iid email now
    retry x5 $ batch $ do
        setType BatchLogged
        setConsistency Quorum
        addPrepQuery cqlInvitation (t, iid, code, email, now)
        addPrepQuery cqlInvitationInfo (code, t, iid)
    return (inv, code)
  where
    cqlInvitationInfo :: PrepQuery W (InvitationCode, TeamId, InvitationId) ()
    cqlInvitationInfo = "INSERT INTO team_invitation_info (code, team, id) VALUES (?, ?, ?)"

    cqlInvitation :: PrepQuery W (TeamId, InvitationId, InvitationCode, Email, UTCTime) ()
    cqlInvitation = "INSERT INTO team_invitation (team, id, code, email, created_at) VALUES (?, ?, ?, ?, ?)"

lookupInvitation :: MonadClient m => TeamId -> InvitationId -> m (Maybe Invitation)
lookupInvitation t r = fmap toInvitation <$>
    retry x1 (query1 cqlInvitation (params Quorum (t, r)))
  where
    cqlInvitation :: PrepQuery R (TeamId, InvitationId) (TeamId, InvitationId, Email, UTCTime)
    cqlInvitation = "SELECT team, id, email, created_at FROM team_invitation WHERE team = ? AND id = ?"

lookupInvitationByCode :: MonadClient m => InvitationCode -> m (Maybe Invitation)
lookupInvitationByCode i = lookupInvitationInfo i >>= \case
    Just InvitationInfo{..} -> lookupInvitation iiTeam iiInvId
    _                       -> return Nothing

lookupInvitationCode :: MonadClient m => TeamId -> InvitationId -> m (Maybe InvitationCode)
lookupInvitationCode t r = fmap runIdentity <$>
    retry x1 (query1 cqlInvitationCode (params Quorum (t, r)))
  where
    cqlInvitationCode :: PrepQuery R (TeamId, InvitationId) (Identity InvitationCode)
    cqlInvitationCode = "SELECT code FROM team_invitation WHERE team = ? AND id = ?"

lookupInvitations :: MonadClient m => TeamId -> Maybe InvitationId -> Range 1 500 Int32 -> m (ResultPage Invitation)
lookupInvitations team start (fromRange -> size) = do
    page <- case start of
        Just ref -> retry x1 $ paginate cqlSelectFrom (paramsP Quorum (team, ref) (size + 1))
        Nothing  -> retry x1 $ paginate cqlSelect (paramsP Quorum (Identity team) (size + 1))
    return $ toResult (hasMore page) $ map toInvitation (trim page)
  where
    trim p = take (fromIntegral size) (result p)
    toResult more invs = cassandraResultPage $ emptyPage { result  = invs
                                                         , hasMore = more
                                                         }
    cqlSelect :: PrepQuery R (Identity TeamId) (TeamId, InvitationId, Email, UTCTime)
    cqlSelect = "SELECT team, id, email, created_at FROM team_invitation WHERE team = ?"

    cqlSelectFrom :: PrepQuery R (TeamId, InvitationId) (TeamId, InvitationId, Email, UTCTime)
    cqlSelectFrom = "SELECT team, id, email, created_at FROM team_invitation WHERE team = ? AND id > ? ORDER BY id ASC"

deleteInvitation :: MonadClient m => TeamId -> InvitationId -> m ()
deleteInvitation t i = do
    code <- lookupInvitationCode t i
    case code of
        Just invCode -> retry x5 $ batch $ do
            setType BatchLogged
            setConsistency Quorum
            addPrepQuery cqlInvitation (t, i)
            addPrepQuery cqlInvitationInfo (Identity invCode)
        Nothing ->
            retry x5 $ write cqlInvitation (params Quorum (t, i))
  where
    cqlInvitation :: PrepQuery W (TeamId, InvitationId) ()
    cqlInvitation = "DELETE FROM team_invitation where team = ? AND id = ?"

    cqlInvitationInfo :: PrepQuery W (Identity InvitationCode) ()
    cqlInvitationInfo = "DELETE FROM team_invitation_info WHERE code = ?"

lookupInvitationInfo :: MonadClient m => InvitationCode -> m (Maybe InvitationInfo)
lookupInvitationInfo ic@(InvitationCode c)
    | c == mempty = return Nothing
    | otherwise   = fmap (toInvitationInfo ic)
                 <$> retry x1 (query1 cqlInvitationInfo (params Quorum (Identity ic)))
  where
    toInvitationInfo i (t, r) = InvitationInfo i t r

    cqlInvitationInfo :: PrepQuery R (Identity InvitationCode) (TeamId, InvitationId)
    cqlInvitationInfo = "SELECT team, id FROM team_invitation_info WHERE code = ?"

-- Helper
toInvitation :: (TeamId, InvitationId, Email, UTCTime) -> Invitation
toInvitation (t, i, e, tm) = Invitation t i e tm
