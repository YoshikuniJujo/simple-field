{-# LANGUAGE BlockArguments, LambdaCase, TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -Wall -fno-warn-tabs #-}

#include <X11/Xlib.h>

module Field.Internal (
	Field(..), openField, destroyField, closeField,
	Mask, exposureMask,
		keyPressMask, keyReleaseMask,
		buttonPressMask, buttonReleaseMask,
		pointerMotionMask, button1MotionMask,
	Event', evEvent, evKeySym, Event(..), withNextEvent, withNextEventTimeout, withNextEventTimeout',
	Position, Dimension, Pixel,
	Field.Internal.drawLine, fillRect, drawImage,
	drawStr, Field.Internal.textExtents, textXOff, clearField, flushField,
	TextUtf8(..),
	Button,
	Field.Internal.drawLines, Point(..),
	keycodeToKeysym
	) where

import Foreign.Ptr
import Foreign.C.Types

import Control.Monad
import Control.Monad.Trans.Control
import Data.Bits
import Data.Word
import Data.Time
import Data.IORef
import System.Posix.Types
import Numeric
import Graphics.X11 hiding (keycodeToKeysym)
import qualified Graphics.X11 as X
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xft
import Graphics.X11.Xrender

import qualified Data.Vector.Storable as V

import TextLike
import Select

data Field = Field {
	display :: Display,
	window :: Window,
	pixmap :: Pixmap,
	screenWidth :: Dimension,
	screenHeight :: Dimension,
	graphicsContext :: GC,
	pendingEvents :: IORef [Event],
	isDeleteEvent :: Event -> Bool }

keycodeToKeysym :: Field -> KeyCode -> CInt -> IO KeySym
keycodeToKeysym = X.keycodeToKeysym . display

openField :: TextUtf8 t => t -> [Mask] -> IO Field
openField nm ms = do
	_ <- initThreads
	dpy <- openDisplay ""
	wmp <- internAtom dpy "WM_PROTOCOLS" True
	del <- internAtom dpy "WM_DELETE_WINDOW" True
	wmn <- internAtom dpy "_NET_WM_NAME" True
	ut8 <- internAtom dpy "UTF8_STRING" True
	let	scr = defaultScreen dpy
		(blk, wht) = (blackPixel dpy scr, whitePixel dpy scr)
		scrW = fromIntegral $ displayWidth dpy scr
		scrH = fromIntegral $ displayHeight dpy scr
	rt <- rootWindow dpy scr

	win <- createSimpleWindow dpy rt 0 0 100 100 1 blk wht
	pxm <- createPixmap dpy win scrW scrH $ defaultDepth dpy scr
	selectInput dpy win $ foldr (.|.) structureNotifyMask ms
	setWMProtocols dpy win [del]
	changeProperty8 dpy win wmn ut8 #{const PropModeReplace} $ utf8 nm
	mapWindow dpy win

	gc <- createGC dpy rt
	setGraphicsExposures dpy gc False

	fillRectangle dpy pxm gc 0 0 scrW scrH

	pes <- newIORef []

	pure . Field dpy win pxm scrW scrH gc pes $ \case
		ClientMessageEvent { ev_message_type = t, ev_data = d0 : _ } ->
			t == wmp && d0 == fromIntegral del
		_ -> False

destroyField :: Field -> IO ()
destroyField Field { display = d, window = w } = destroyWindow d w

closeField :: Field -> IO ()
closeField Field { display = d } = do
	setCloseDownMode d #const AllTemporary
	closeDisplay d

data Event' = Event' { evEvent :: Event, evKeySym :: Maybe KeySym } deriving Show

mkEvent' :: Field -> Event -> IO Event'
mkEvent' f ev = Event' ev <$> case ev of
	KeyEvent {} -> Just <$> keycodeToKeysym f (ev_keycode ev) (fromIntegral $ ev_state ev .&. shiftMask)
	_ -> pure Nothing

withNextEvent :: MonadBaseControl IO m => Field -> (Event' -> m a) -> m a
withNextEvent f@Field { display = d } act =
	liftBaseWith (\run -> allocaXEvent $ \e -> run . act =<< mkEvent' f =<< nextEvent d e *> getEvent e) >>= restoreM

withNextEventTimeout :: MonadBaseControl IO m => Field -> Word32 -> ([Event] -> m a) -> m a
withNextEventTimeout Field { display = d } n act =
	liftBaseWith (\run -> run . act =<< do
		sync d False
		es <- allEvent d
		case es of
			[] -> do
				to <- myWaitForEvent d $ fromIntegral n / 1000000
				(if to then pure [] else allEvent d)
			_ -> pure es) >>= restoreM

withNextEventTimeout' :: MonadBaseControl IO m => Field -> DiffTime -> (Maybe Event' -> m a) -> m a
withNextEventTimeout' f@Field { display = d, pendingEvents = pes } (round . (* 1000000) -> n) act =
	liftBaseWith (\run -> run . act =<< maybe (pure Nothing) ((Just <$>) . mkEvent' f) =<< do
		readIORef pes >>= \case
			[] -> do
				sync d False
				ea <- allEvent d
				case ea of
					[] -> do
						to <- myWaitForEvent d $ fromIntegral (n :: Word32) / 1000000
						if to then pure Nothing else do
							e : es <- allEvent d
							Just e <$ writeIORef pes es
					e : es -> Just e <$ writeIORef pes es
			e : es -> Just e <$ writeIORef pes es
	) >>= restoreM

getNextEvent :: Display -> IO Event
getNextEvent d = allocaXEvent \e -> do
	nextEvent d e
	getEvent e

allEvent :: Display -> IO [Event]
allEvent d = do
	n <- pending d
	if n == 0 then pure [] else do
		(++) <$> fromIntegral n `replicateM` getNextEvent d <*> allEvent d

drawLines :: Field -> Pixel -> CInt -> [Point] -> IO ()
drawLines Field { display = dpy, pixmap = win, graphicsContext = gc } c lw ps = do
	setLineAttributes dpy gc lw lineSolid capRound joinRound
	setForeground dpy gc c >> X.drawLines dpy win gc ps coordModeOrigin

fillRect :: Field ->
	Pixel -> Position -> Position -> Dimension -> Dimension -> IO ()
fillRect Field { display = dpy, pixmap = win, graphicsContext = gc } c x y w h =
	setForeground dpy gc c >> fillRectangle dpy win gc x y w h

drawStr :: Field -> Pixel -> String -> Double -> Position -> Position -> String -> IO ()
drawStr Field { display = dpy, pixmap = win } c fnt sz x y str = do
	let	vsl = defaultVisual dpy $ defaultScreen dpy
		cm = defaultColormap dpy $ defaultScreen dpy
	draw <- xftDrawCreate dpy win vsl cm
	font <- xftFontOpen dpy (defaultScreenOfDisplay dpy) $
		fnt ++ "-" ++ showFFloat (Just 0) sz ""
	withXftColorValue dpy vsl cm XRenderColor {
		xrendercolor_red = (fromIntegral c `shiftR` 16) `shiftL` 8,
		xrendercolor_blue = (fromIntegral c `shiftR` 8 .&. 0xff) `shiftL` 8,
		xrendercolor_green = (fromIntegral c .&. 0xff) `shiftL` 8,
		xrendercolor_alpha = 0xffff } \clr ->
		xftDrawString draw clr font x y str

textExtents :: Field -> String -> Double -> String -> IO XGlyphInfo
textExtents Field { display = dpy } fnt sz str = do
	font <- xftFontOpen dpy (defaultScreenOfDisplay dpy)
		$ fnt ++ "-" ++ showFFloat (Just 0) sz ""
	xftTextExtents dpy font str

textXOff :: Field -> String -> Double -> String -> IO Int
textXOff Field { display = dpy } fnt sz str = do
	font <- xftFontOpen dpy (defaultScreenOfDisplay dpy)
		$ fnt ++ "-" ++ showFFloat (Just 0) sz ""
	xglyphinfo_xOff <$> xftTextExtents dpy font str


drawLine :: Field -> Pixel -> CInt -> Position -> Position -> Position -> Position -> IO ()
drawLine Field { display = dpy, pixmap = win, graphicsContext = gc } c lw x1 y1 x2 y2 = do
	setForeground dpy gc c
	setLineAttributes dpy gc lw lineSolid capRound joinRound
	X.drawLine dpy win gc x1 y1 x2 y2


clearField :: Field -> IO ()
clearField Field { display = dpy, pixmap = win, graphicsContext = gc, screenWidth = w, screenHeight = h } =
	setForeground dpy gc 0x000000 >> fillRectangle dpy win gc 0 0 w h -- clearWindow dpy win

flushField :: Field -> IO ()
flushField Field { display = dpy, window = win, pixmap = pxm, graphicsContext = gc, screenWidth = w, screenHeight = h } = do
	copyArea dpy pxm win gc 0 0 w h 0 0
	flush dpy

myWaitForEvent :: Display -> NominalDiffTime -> IO Bool
myWaitForEvent d n = do
	fds <- select [Fd fd] [] [] n
	pure $ (Fd fd) `notElem` fds
	where fd = connectionNumber d

drawImage :: Field -> V.Vector Word8 -> Position -> Position -> Dimension -> Dimension -> IO ()
drawImage f dt x y w h =
	V.unsafeWith (V.unsafeCast dt) \d -> do
		i <- createImageSimple f d w h
		putImage' f i x y w h

createImage' :: Field -> CInt -> X.ImageFormat -> CInt -> Ptr CChar -> Dimension -> Dimension -> CInt -> CInt -> IO X.Image
createImage' Field { display = dpy } depth format offset dat width height bitmap_pad bytes_per_line =
	X.createImage dpy vis depth format offset dat width height bitmap_pad bytes_per_line
	where
	vis = X.defaultVisual dpy (X.defaultScreen dpy)

createImageSimple :: Field -> Ptr CChar -> Dimension -> Dimension -> IO X.Image
createImageSimple f@Field { display = dpy } dat width height =
	createImage' f (defaultDepth' f) X.zPixmap 0 dat width height (X.bitmapUnit dpy) 0

putImage' :: Field -> X.Image -> Position -> Position -> Dimension -> Dimension -> IO ()
putImage' Field { display = dpy, pixmap = win, graphicsContext = gc } img x y w h =
	X.putImage dpy win gc img 0 0 x y w h

defaultDepth' :: Field -> CInt
defaultDepth' Field { display = dpy } = X.defaultDepth dpy (X.defaultScreen dpy)
