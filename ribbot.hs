import Data.Either
import Data.List
import Network
import System.IO
import System.IO.Unsafe
import System.Exit
import Control.Arrow
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Exception as Ex
import Text.Printf
import Prelude hiding (catch)
import Cards -- Cards.hs module in the same directory as this file
import Title -- Title.hs module in same directory


-- Net monad, wrapper over IO, carrying the bot's immutable state
data Bot = Nope | Bot { socket :: Handle -- Nope is the most bullshit way to solve my problem
                      , game :: Game }
type Net = StateT Bot IO

server = "irc.freenode.org"
port = 6667
chan = "#testmattbot"
nick = "testmattbot"

main = Ex.bracket connect disconnect loop
  where
    disconnect = hClose . socket
    loop st    = (runStateT run st) `Ex.catch` (\(SomeException _) -> return ((), Nope))
    -- state monad expected a ((), Bot) so I redefined bot. Nope = dummy type

-- connect to server and return initial bot state
connect :: IO Bot
connect = notify $ do
    h <- connectTo server (PortNumber port)
    hSetBuffering h NoBuffering
    return (Bot h None) -- initially no game will be in progress
    -- nested return is probably really stupid
  where
    notify a = Ex.bracket_
      (printf "Connecting to %s ... " server >> hFlush stdout)
      (putStrLn "done.")
      a

run :: Net ()
run = do
    write "NICK" nick
    write "USER" (nick ++ " 0 * :matt testing a bot")
    write "JOIN" chan
    gets socket >>= listen

listen :: Handle -> Net ()
listen h = forever $ do
  s <- init `fmap` io (hGetLine h)
  io (putStrLn s)
  if ping s
    then pong s
  else do
    scan (tokenize s)
    eval (tokenize s)
  where
    forever a = a >> forever a
    ping x = "PING :" `isPrefixOf` x
    pong x = write "PONG" (':' : drop 6 x)

-- Separate into name, command, target, whatever else, and message
tokenize s = words (fst tmp) ++ ((drop 1 (snd tmp)) : [])
    where tmp = span (/=':') $ drop 1 s

-- Scan for passive bot cues
scan :: [String] -> Net () -- This function is messy!
scan xs = do
    a <- io $ liftM rights $ sequence $ fmap getTitle (findURLs s) -- Extract [String] from [IO (Either ParserError String)] 
    mapM_ (\x -> privmsg chan ("Link Title: [ " ++ x ++ " ]")) a;
    where s = drop 1 (last xs)

-- Evaluate active bot commands
eval :: [String] -> Net ()
eval (x:xs) | "!id" `isPrefixOf` msg && "hattmammerly" == user = privmsg chan $ drop 4 msg
            | ("!quit" == msg) && ("hattmammerly" == user)
                 = write "QUIT" ":Exiting" >> io (exitWith ExitSuccess)
            | "!uno " `isPrefixOf` msg = do -- send game and line to uno
                 g <- gets game
                 updateGame $ uno (user : (tail (init xs)) ++ [(drop 5 msg)]) g
            | "!show" == msg = do g <- gets game; showGame g
            | "!put" == msg = do h <- gets socket; put $ Bot h (Game [] [] [(chan,"test")])
            | "!seq" == msg = privmsgSeq $ zip(take 3 $ repeat "#testmattbot") ["one", "two", "three"] 
            where 
                msg = last xs
                user = takeWhile (/='!') x
eval _ = return ()

-- Send a privmsg to given channel on freenode
privmsg :: String -> String -> Net ()
privmsg ch s = write "PRIVMSG" (ch ++ " :" ++ s)

-- Send a message to the server
-- -- -- Command -> Value
write :: String -> String -> Net ()
write s t = do
  h <- gets socket
  io $ hPrintf h "%s %s\r\n" s t
  io $ printf   ">%s %s\n"   s t

-- Convenience -- haskellwiki had this. I see no value.
io :: IO a -> Net a
io = liftIO

-- List of (Target, msg) -- execute all writes
privmsgSeq ((ch, msg) : msgs) = do
    privmsg ch msg
    privmsgSeq msgs
privmsgSeq [] = return ()

-- Sends queued messages and returns the bot with the updated game state
-- Can probably be cleaned up a tad
updateGame :: IO Game -> Net ()
updateGame iogame = do
    h <- gets socket
--    showGame game
    case game of None -> put $ Bot h game
                 Organizing players decks msgs -> do
                     privmsgSeq msgs
                     put $ Bot h (Organizing players decks [])
                 Game players decks msgs -> do
                     privmsgSeq msgs
                     put $ Bot h (Game players decks [])
                 Suspended players decks msgs -> do
                     privmsgSeq msgs
                     put $ Bot h (Suspended players decks [])
    where game = unsafePerformIO iogame

-- Write the game to #testmattbot for debugging I guess
showGame :: Game -> Net ()
showGame game = do
    privmsg chan (show game)

-- Uno game logic
-- first player in list takes turn, popped, appended to end of list 
uno :: [String] -> Game -> IO Game
uno xs game = do
    -- tentatively just return something with a message to be fired off
    -- time to implement game logic! or, it will be after math lecture
    case tokens of [] -> return game
                   ("id":xs) -> return game
                   ("addmsg":xs) -> return $ addMsg (chan, "test!") game
                   ("test":xs) -> return (Game [] [] [("#testmattbot","test!!!")])
                   ("status":xs) -> return $ addMsg (chan, show game) game
                   ("aye":xs) -> return $ addPlayer (user, [], 0) game
--    case game of None -> return (Organizing [] [] [("#testmattbot", "test!")])
--                 Organizing ps ds ms -> return (Organizing ps ds [("#testmattbot","test!")])
--                 Game ps ds ms -> return (Game ps ds [("#testmattbot","test!")])
--                 Suspended ps ds ms -> return (Suspended ps ds [("#testmattbot","test!")])
    -- gen <- getStdGen -- need to import random stuff, maybe push to other file
    where tokens = words $ last xs
          user = takeWhile (/='!') $ head xs
