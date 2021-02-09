{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Mosquitto where

import           Data.Coerce (coerce)
import           Data.Monoid ((<>))
import           Control.Monad
import           Foreign.C.Types
import           Foreign.ForeignPtr (ForeignPtr, withForeignPtr, newForeignPtr_)
import           Foreign.Ptr ( Ptr, nullPtr, castPtr, FunPtr)
import           Foreign.Marshal.Alloc ( alloca )
import           Foreign.C.String (peekCString, peekCStringLen)

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import           Language.C.Inline.TypeLevel

import           System.IO.Unsafe (unsafePerformIO)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BS

import           Network.Mosquitto.Internal.Types
import           Network.Mosquitto.Internal.Inline
import           Foreign.Storable

fromCBool :: CBool -> Bool
fromCBool (CBool n) = n > 0

toCBool :: Bool -> CBool
toCBool True = CBool 1
toCBool False = CBool 0

C.context (C.baseCtx <> C.vecCtx <> C.funCtx <> mosquittoCtx)
C.include "<stdio.h>"
C.include "<mosquitto.h>"

c'MessageToMMessage :: Ptr C'Message -> IO Message
c'MessageToMMessage ptr =
   Message
    <$> (fromIntegral <$> [C.exp| int { $(struct mosquitto_message * ptr)->mid}  |])
    <*> (peekCString =<< [C.exp| char * {$(struct mosquitto_message * ptr) -> topic } |])
    <*> (C8.packCStringLen =<< (,)
             <$> [C.exp| char * {$(struct mosquitto_message * ptr) -> payload } |]
             <*> fmap fromIntegral [C.exp| int {$(struct mosquitto_message * ptr) -> payloadlen } |])
    <*> (fromIntegral <$> [C.exp| int { $(struct mosquitto_message * ptr)->qos}  |])
    <*> (fromCBool <$> [C.exp| bool { $(struct mosquitto_message * ptr)->retain}  |])

{-# NOINLINE init #-}
init = [C.exp| int{ mosquitto_lib_init() }|]

{-# NOINLINE cleanup #-}
cleanup = [C.exp| int{ mosquitto_lib_cleanup() }|]

withMosquittoLibrary :: IO a -> IO a
withMosquittoLibrary f = Network.Mosquitto.init *> f <* cleanup

{-# NOINLINE version #-}
version :: (Int, Int, Int)
version = unsafePerformIO $
  alloca $ \a -> alloca $ \b -> alloca $ \c -> do
      [C.block|void{ mosquitto_lib_version($(int *a),$(int *b),$(int *c)); }|]
      (,,) <$> peek' a
           <*> peek' b
           <*> peek' c
 where
   peek' x = fromIntegral <$> peek x

strerror :: Int -> IO (String)
strerror (fromIntegral -> mosq_errno) = peekCString =<< [C.exp| const char * {
    mosquitto_strerror($(int mosq_errno))
  }|]

newMosquitto :: Bool -> String -> Maybe a -> IO (Mosquitto a)
newMosquitto clearSession (C8.pack -> userId) _userData = do
   let clearSession' = toCBool clearSession
   fp <- newForeignPtr_ <$> [C.block|struct mosquitto *{
        struct mosquitto * p =
          mosquitto_new( $bs-cstr:userId
                       , $(bool clearSession')
                       , 0 // (void * ptrUserData)
                       );
        mosquitto_threaded_set(p, true);
        return p;
      }|]

   Mosquitto <$> fp

destroyMosquitto :: Mosquitto a -> IO ()
destroyMosquitto ms = withPtr ms $ \ptr ->
   [C.exp|void{
         mosquitto_destroy($(struct mosquitto *ptr))
     }|]

setTls :: Mosquitto a -> String -> String -> String -> IO ()
setTls mosq (C8.pack -> caFile) (C8.pack -> certFile) (C8.pack -> keyFile) =
  withPtr mosq $ \pMosq ->
       [C.exp|void{
               mosquitto_tls_set( $(struct mosquitto *pMosq)
                                , $bs-cstr:caFile
                                , 0
                                , $bs-cstr:certFile
                                , $bs-cstr:keyFile
                                , 0
                                )
       }|]

setTlsNoClientCert :: Mosquitto a -> String -> IO ()
setTlsNoClientCert mosq (C8.pack -> caFile) =
  withPtr mosq $ \pMosq ->
       [C.exp|void{
               mosquitto_tls_set( $(struct mosquitto *pMosq)
                                , $bs-cstr:caFile
                                , 0
                                , 0
                                , 0
                                , 0
                                )
       }|]

setReconnectDelay
  :: Mosquitto a -- ^ mosquitto instance
  -> Bool        -- ^ exponential backoff
  -> Int         -- ^ initial backoff
  -> Int         -- ^ maximum backoff
  -> IO Int
setReconnectDelay mosq  exponential (fromIntegral -> reconnectDelay) (fromIntegral -> reconnectDelayMax) = do
  let exponential' = toCBool exponential
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_reconnect_delay_set
               ( $(struct mosquitto *pMosq)
               , $(int reconnectDelay)
               , $(int reconnectDelayMax)
               , $(bool exponential')
               )
        }|]

setUsernamePassword
  :: Mosquitto a -- ^ mosquitto instance
  -> String      -- ^ username
  -> String      -- ^ password
  -> IO Int
setUsernamePassword mosq (C8.pack -> user) (C8.pack -> pwd) =
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
              mosquitto_username_pw_set
                ( $(struct mosquitto *pMosq)
                , $bs-cstr:user
                , $bs-cstr:pwd
                )
       }|]

connect :: Mosquitto a -> String -> Int -> Int -> IO Int
connect mosq (C8.pack -> hostname) (fromIntegral -> port) (fromIntegral -> keepAlive) =
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
               mosquitto_connect( $(struct mosquitto *pMosq)
                                , $bs-cstr:hostname
                                , $(int port)
                                , $(int keepAlive)
                                )
             }|]

disconnect :: Mosquitto a -> IO Int
disconnect mosq =
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
               mosquitto_disconnect( $(struct mosquitto *pMosq) )
             }|]

onSubscribe :: Mosquitto a -> OnSubscribe -> IO ()
onSubscribe mosq onSubscribe =  do
  on_subscribe <- mkCOnSubscribe $ \_ _ mid (fromIntegral -> ii) iis ->
      onSubscribe (fromIntegral mid) =<< mapM (fmap fromIntegral . peekElemOff iis) [0..ii-1]
  withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_subscribe_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_subscribe)(struct mosquitto *,void *, int, int, const int *))
            );
       }|]


onConnect :: Mosquitto a -> OnConnection -> IO ()
onConnect mosq onConnect =  do
  on_connect <- mkCOnConnection $ \_ _ ii -> onConnect (fromIntegral ii)
  withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_connect_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_connect)(struct mosquitto *,void *, int))
            );
       }|]

onDisconnect :: Mosquitto a -> OnConnection -> IO ()
onDisconnect mosq onDisconnect =  do
  on_disconnect <- mkCOnConnection $ \_ _ ii -> onDisconnect (fromIntegral ii)
  withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_disconnect_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_disconnect)(struct mosquitto *,void *, int))
            );
       }|]

onLog :: Mosquitto a -> OnLog -> IO ()
onLog mosq onLog =  do
  on_log <- mkCOnLog $ \_ _ ii mm -> onLog (fromIntegral ii) =<< peekCString mm
  withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_log_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_log)(struct mosquitto *,void *, int, const char *))
            );
       }|]

onMessage :: Mosquitto a -> OnMessage -> IO ()
onMessage mosq onMessage =  do
    on_message <- mkCOnMessage $ \_ _ mm -> (onMessage =<< c'MessageToMMessage mm)
    withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_message_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_message)(struct mosquitto *, void *, const struct mosquitto_message *))
            );
       }|]

onPublish :: Mosquitto a -> OnPublish -> IO ()
onPublish mosq onPublish =  do
  on_publish <- mkCOnPublish $ \_ _ mid -> onPublish (fromIntegral mid)
  withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_publish_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_publish)(struct mosquitto *,void *, int))
            );
       }|]

loop :: Mosquitto a -> IO ()
loop mosq =
  withPtr mosq $ \pMosq ->
    [C.exp|void{
             mosquitto_loop($(struct mosquitto *pMosq), -1, 1)
        }|]

loopForever :: Mosquitto a -> IO ()
loopForever mosq = do
    _ <- loopForeverExt mosq (-1)
    return()

loopForeverExt :: Mosquitto a -> Int -> IO Int
loopForeverExt mosq (fromIntegral -> timeout)  =
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_loop_forever($(struct mosquitto *pMosq), $(int timeout), 1)
        }|]

setTlsInsecure :: Mosquitto a -> Bool -> IO ()
setTlsInsecure mosq isInsecure = do
  let isInsecure' = toCBool isInsecure
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_tls_insecure_set($(struct mosquitto *pMosq), $(bool isInsecure'))
        }|]

setWill :: Mosquitto a -> Bool -> Int -> String -> S.ByteString -> IO Int
setWill mosq retain (fromIntegral -> qos) (C8.pack -> topic) payload = do
  let retain' = toCBool retain
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_will_set
               ( $(struct mosquitto *pMosq)
               , $bs-cstr:topic
               , $bs-len:payload
               , $bs-ptr:payload
               , $(int qos)
               , $(bool retain')
               )
        }|]

clearWill :: Mosquitto a -> IO Int
clearWill mosq = fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_will_clear($(struct mosquitto *pMosq))
        }|]

publish :: Mosquitto a -> Bool -> Int -> String -> S.ByteString -> IO ()
publish mosq retain (fromIntegral -> qos) (C8.pack -> topic) payload = do
  let retain' = toCBool retain
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_publish
               ( $(struct mosquitto *pMosq)
               , 0
               , $bs-cstr:topic
               , $bs-len:payload
               , $bs-ptr:payload
               , $(int qos)
               , $(bool retain')
               )
        }|]

subscribe :: Mosquitto a -> Int -> String -> IO ()
subscribe mosq (fromIntegral -> qos) (C8.pack -> topic) =
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_subscribe
               ( $(struct mosquitto *pMosq)
               , 0
               , $bs-cstr:topic
               , $(int qos)
               )
        }|]

