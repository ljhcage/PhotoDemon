VERSION 5.00
Begin VB.UserControl pdNavigatorInner 
   Appearance      =   0  'Flat
   BackColor       =   &H80000005&
   ClientHeight    =   3600
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4800
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   ScaleHeight     =   240
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   320
   ToolboxBitmap   =   "pdNavigatorInner.ctx":0000
End
Attribute VB_Name = "pdNavigatorInner"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Navigation custom control (inner panel)
'Copyright 2015-2019 by Tanner Helland
'Created: 16/October/15
'Last updated: 22/August/19
'Last update: overhaul control to support new animation mode
'
'For implementation details, please refer to the main pdNavigator control.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit https://photodemon.org/license/
'
'***************************************************************************

Option Explicit

'If the control is resized at run-time, it will request a new thumbnail via this function.  The passed DIB will already
' be sized to the
Public Event RequestUpdatedThumbnail(ByRef thumbDIB As pdDIB, ByRef thumbX As Single, ByRef thumbY As Single, ByRef srcImage As pdImage)

'When the user interacts with the navigation box, the (x, y) coordinates *in image space* will be returned in this event.
Public Event NewViewportLocation(ByVal imgX As Single, ByVal imgY As Single)

'Animation sometimes raises its own events
Public Event AnimationEnded()
Public Event AnimationFrameChanged(ByVal newFrameIndex As Long)

'Because VB focus events are wonky, especially when we use CreateWindow within a UC, this control raises its own
' specialized focus events.  If you need to track focus, use these instead of the default VB functions.
Public Event GotFocusAPI()
Public Event LostFocusAPI()

'The image thumbnail is cached independently, so we only request updates when absolutely necessary.
Private m_ImageThumbnail As pdDIB

'This value will be TRUE while the mouse is inside the navigator box
Private m_MouseInsideBox As Boolean

'Padding (in pixels) between the edges of the control and the image thumbnail.  This is automatically adjusted for
' DPI at run-time.
Private Const THUMB_PADDING As Long = 3

'When the control raises a request for a new thumbnail image, that function will supply an (optional?) (x, y) pair detailing
' where the thumb is centered within the navigator.  We use this to know where the image lies inside the thumb.
Private m_ThumbEventX As Single, m_ThumbEventY As Single

'The rect where the image thumbnail has been drawn.  This is calculated by the RedrawBackBuffer function.
Private m_ThumbRect As RectF, m_ImageRegion As RectF

'Last mouse (x, y) values.  We track these so we know whether to highlight the region box inside the navigator.
Private m_LastMouseX As Single, m_LastMouseY As Single

'If our parent image is animated, we need to track a whole bunch of exciting things
Private m_Animated As Boolean

Private Type PD_AnimationFrame
    
    afDIB As pdDIB
    afFrameDelayMS As Long
    afHash As Long
    afTimeStamp As Currency
    
    'At present, all animation frames default to the same size.  This may change in the future.
    afOffsetX As Single
    afOffsetY As Single
    
End Type

Private m_RepeatAnimation As Boolean
Private m_Frames() As PD_AnimationFrame
Private m_FrameCount As Long, m_CurrentFrame As Long
Private m_TimeAtLastFrame As Currency, m_ExpectedTimeToDisplay As Currency
Private WithEvents m_Timer As pdTimer
Attribute m_Timer.VB_VarHelpID = -1

'These values are only used for profiling; they can be commented-out in production code
Private m_FramesDisplayed As Long, m_FrameTimes As Double

'ID of the last associated image.  When this value changes, we reset all animation parameters.
Private m_LastImageID As String, m_LastThumbWidth As Long, m_LastThumbHeight As Long
Private m_AniThumbBounds As RectF
Private m_DoNotRenderAnimation As Boolean

'User control support class.  Historically, many classes (and associated subclassers) were required by each user control,
' but I've since attempted to wrap these into a single master control support class.
Private WithEvents ucSupport As pdUCSupport
Attribute ucSupport.VB_VarHelpID = -1

'Local list of themable colors.  This list includes all potential colors used by this class, regardless of state change
' or internal control settings.  The list is updated by calling the UpdateColorList function.
' (Note also that this list does not include variants, e.g. "BorderColor" vs "BorderColor_Hovered".  Variant values are
'  automatically calculated by the color management class, and they are retrieved by passing boolean modifiers to that
'  class, rather than treating every imaginable variant as a separate constant.)
Private Enum PDNAVINNER_COLOR_LIST
    [_First] = 0
    PDNI_Background = 0
    [_Last] = 0
    [_Count] = 1
End Enum

'Color retrieval and storage is handled by a dedicated class; this allows us to optimize theme interactions,
' without worrying about the details locally.
Private m_Colors As pdThemeColors

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_NavigatorInner
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    UserControl.Enabled = newValue
    RedrawBackBuffer
    PropertyChanged "Enabled"
End Property

Public Property Get hWnd() As Long
    hWnd = UserControl.hWnd
End Property

Public Property Get ContainerHwnd() As Long
    ContainerHwnd = UserControl.ContainerHwnd
End Property

Public Function GetAnimationRepeat() As Boolean
    GetAnimationRepeat = m_RepeatAnimation
End Function

Public Sub SetAnimationRepeat(ByVal newState As Boolean)
    m_RepeatAnimation = newState
End Sub

Private Sub m_Timer_Timer()
        
    'Failsafe check for "still animating".  (Remember that WM_TIMER messages are low-priority; they may
    ' stack up as other messages are processed.)
    If (Not m_Timer.IsActive) Then Exit Sub
        
    'Failsafe check for frame count
    If OutOfFrames() Then Exit Sub
    
    'Notify outside callers of the frame change
    RaiseEvent AnimationFrameChanged(m_CurrentFrame)
    
    'Delays are calculated according to the *previous* frame's delay
    Dim relevantFrame As Long
    relevantFrame = m_CurrentFrame - 1
    
    If (relevantFrame < 0) And m_RepeatAnimation Then relevantFrame = m_FrameCount - 1
    
    'If this frame went over-budget, we want to subtract the difference from the next frame's
    ' requested delay; as long as delays are small, this is enough to keep rendering reasonably
    ' well synchronized.
    Dim frameDeficit As Currency, timeElapsedMS As Currency
    frameDeficit = 0
    
    'Perform drop-frame testing (but never on the first frame!)
    If (relevantFrame >= 0) And (m_ExpectedTimeToDisplay <> 0) Then
        
        'If more time has elapsed than the frame delay we originally requested, we may need to skip
        ' the current frame - and possibly even more frames after that.  (Note that timer events are
        ' not especially precise, especially on Win 8+ because we use coalescing timers to improve
        ' battery life - so the likelihood of a "perfect" timer interval is very low.)
        timeElapsedMS = (VBHacks.GetHighResTimeInMSEx() - m_ExpectedTimeToDisplay)
        
        If (timeElapsedMS > 0@) Then
            
            'This frame arrived late.
            
            'See if we're also over-budget for the next frame in line (by measuring the delay of
            ' the *current* frame - remember, delays in animated files specify the delay *after*
            ' the current frame).
            If (timeElapsedMS > m_Frames(m_CurrentFrame).afFrameDelayMS) Then
                
                'Damn - we're too late to render this frame in time.  Start searching through the
                ' frame list until we arrive at the frame nearest our current delay.
                Dim netDelay As Long
                netDelay = m_Frames(m_CurrentFrame).afFrameDelayMS
                relevantFrame = GetNextFrame(m_CurrentFrame)
                
                'We'll also add a failsafe check for long delays, in case something crazy happens
                ' like suspending the PC mid-animation, then returning later
                Const MAX_FRAMES_SKIPPED As Long = 15
                Dim numFramesSkipped As Long
                numFramesSkipped = 0
                
                Do While (timeElapsedMS > netDelay) And (relevantFrame < m_FrameCount) And (numFramesSkipped < MAX_FRAMES_SKIPPED)
                
                    'Increment the net delay
                    netDelay = netDelay + m_Frames(relevantFrame).afFrameDelayMS
                    relevantFrame = GetNextFrame(relevantFrame)
                    numFramesSkipped = numFramesSkipped + 1
                
                Loop
                
                'The net delay now exceeds the delay that has already occurred.  Calculate a time deficit,
                ' then display the frame *before* the currently calculated one.
                relevantFrame = relevantFrame - 1
                If (relevantFrame < 0) Then relevantFrame = m_FrameCount - 1
                netDelay = netDelay - m_Frames(relevantFrame).afFrameDelayMS
                
                frameDeficit = -1 * (timeElapsedMS - netDelay)
                
                'Note that we don't need to check "repeat animation" status here, as a single-play animation
                ' will still want to display the final frame before exiting
                m_CurrentFrame = relevantFrame
                
            'This frame arrived late, but there's still plenty of time to display it.  Subtract the
            ' already-acquired delay amount from our next timer request, which will hopefully bring
            ' timings back in line.
            Else
                frameDeficit = -1 * Int(timeElapsedMS + 0.5)
            End If
            
        'Frame is early or exactly on-time.  Calculate a frame deficit, if any, which we'll add to
        ' the next frame's delay.  (This helps correct for millisecond-level variations in timer events.)
        Else
            frameDeficit = Int(timeElapsedMS + 0.5)
        End If
    
    End If
    
    'Want to know average frame-times?  Uncomment these lines.
    'm_FramesDisplayed = m_FramesDisplayed + 1
    'm_FrameTimes = m_FrameTimes + (VBHacks.GetHighResTimeInMSEx() - m_TimeAtLastFrame)
    'Debug.Print Format$(CDbl(m_FrameTimes) / CDbl(m_FramesDisplayed), "0.000")
    
    'Note the current time (so the next frame has a reference point)
    VBHacks.GetHighResTimeInMS m_TimeAtLastFrame
    
    'Render the current frame
    RenderAnimationFrame
    
    'Advance the frame counter
    m_CurrentFrame = m_CurrentFrame + 1
    
    'If infinite repeats are active, roll the frame counter around m_framecount
    If m_RepeatAnimation And (m_CurrentFrame >= m_FrameCount) Then m_CurrentFrame = 0
    
    'If frames remain, figure out an appropriate timer interval for the next frame
    If (m_CurrentFrame < m_FrameCount) Then
        
        relevantFrame = m_CurrentFrame - 1
        If (relevantFrame < 0) Then relevantFrame = m_FrameCount - 1
        
        Dim timeIntervalToRequest As Long
        timeIntervalToRequest = m_Frames(relevantFrame).afFrameDelayMS + frameDeficit
        
        'Cache what time we expect the next frame to display; the next iteration will use this value
        ' to recenter itself accordingly.
        m_ExpectedTimeToDisplay = m_TimeAtLastFrame + timeIntervalToRequest
        
        'Windows timers don't allow timers to trigger faster than 10 ms
        If (timeIntervalToRequest < 10) Then timeIntervalToRequest = 10
        m_Timer.Interval = timeIntervalToRequest
    
    'This is a 1x animation.  Ensure the frame position is valid, then exit
    Else
        m_CurrentFrame = m_FrameCount - 1
        StopAnimation
    End If
    
End Sub

'Given a frame index, return the "next" one.  For loop animations, this automatically wraps frame indices.
' For non-repeating animations, this will return an invalid index (m_FrameCount) by design.  You must
' check for this return and respond accordingly.
Private Function GetNextFrame(ByVal curFrame As Long) As Long
    GetNextFrame = curFrame + 1
    If (GetNextFrame >= m_FrameCount) Then
        If m_RepeatAnimation Then GetNextFrame = 0
    End If
End Function

'Check to see if we've run out of frames to display; this is used for "play once" functionality
Private Function OutOfFrames() As Boolean
    
    OutOfFrames = False
    
    'Failsafe check for frame count
    If (m_CurrentFrame >= m_FrameCount) Then
        If m_RepeatAnimation Then
            m_CurrentFrame = 0
        Else
            m_CurrentFrame = m_FrameCount - 1
            StopAnimation
            OutOfFrames = True
        End If
    End If
    
End Function

Private Sub ucSupport_CustomMessage(ByVal wMsg As Long, ByVal wParam As Long, ByVal lParam As Long, bHandled As Boolean, lReturn As Long)
    If (wMsg = WM_PD_COLOR_MANAGEMENT_CHANGE) Then Me.NotifyNewThumbNeeded
End Sub

Private Sub ucSupport_GotFocusAPI()
    RaiseEvent GotFocusAPI
End Sub

Private Sub ucSupport_LostFocusAPI()
    RaiseEvent LostFocusAPI
End Sub

'To support high-DPI settings properly, we expose some specialized move+size functions
Public Function GetLeft() As Long
    GetLeft = ucSupport.GetControlLeft
End Function

Public Sub SetLeft(ByVal newLeft As Long)
    ucSupport.RequestNewPosition newLeft, , True
End Sub

Public Function GetTop() As Long
    GetTop = ucSupport.GetControlTop
End Function

Public Sub SetTop(ByVal newTop As Long)
    ucSupport.RequestNewPosition , newTop, True
End Sub

Public Function GetWidth() As Long
    GetWidth = ucSupport.GetControlWidth
End Function

Public Sub SetWidth(ByVal newWidth As Long)
    ucSupport.RequestNewSize newWidth, , True
End Sub

Public Function GetHeight() As Long
    GetHeight = ucSupport.GetControlHeight
End Function

Public Sub SetHeight(ByVal newHeight As Long)
    ucSupport.RequestNewSize , newHeight, True
End Sub

Public Sub SetPositionAndSize(ByVal newLeft As Long, ByVal newTop As Long, ByVal newWidth As Long, ByVal newHeight As Long)
    ucSupport.RequestFullMove newLeft, newTop, newWidth, newHeight, True
End Sub

Public Function GetCurrentFrame() As Long
    GetCurrentFrame = m_CurrentFrame
End Function

'If the mouse button is clicked inside the image portion of the navigator, scroll to that (x, y) position
Private Sub ucSupport_MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)
    
    'Skip overlays while animating (the animator responds to clicks, instead)
    If (m_Timer.IsActive) Then Exit Sub
            
    If (Button And pdLeftButton) <> 0 Then
        If PDMath.IsPointInRectF(x, y, m_ImageRegion) Then ScrollToXY x, y
    End If
    
End Sub

Private Sub ucSupport_MouseEnter(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    m_MouseInsideBox = True
End Sub

Private Sub ucSupport_MouseLeave(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    m_MouseInsideBox = False
    m_LastMouseX = -1: m_LastMouseY = -1
    ucSupport.RequestCursor IDC_DEFAULT
    
    'Skip overlays while animation
    If (Not m_Timer.IsActive) Then RedrawBackBuffer
    
End Sub

Private Sub ucSupport_MouseMoveCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)
    
    m_LastMouseX = x: m_LastMouseY = y
    
    'Set the cursor depending on whether the mouse is inside the image portion of the navigator control
    If PDMath.IsPointInRectF(x, y, m_ImageRegion) Then
        ucSupport.RequestCursor IDC_HAND
    Else
        ucSupport.RequestCursor IDC_DEFAULT
    End If
    
    'Skip overlays while animating
    If (m_Timer.IsActive) Then Exit Sub
    
    'If the mouse button is down, scroll to that (x, y) position.  Note that we don't care if the cursor is in-bounds;
    ' the ScrollToXY function will automatically fix that for us.
    If (Button And pdLeftButton) <> 0 Then
        ScrollToXY x, y
    Else
        RedrawBackBuffer
    End If
    
End Sub

'Outside callers can modify the currently active frame using this slider.
Public Sub ChangeActiveFrame(ByVal newFrameIndex As Long)
    If (newFrameIndex <> m_CurrentFrame) Then
        StopAnimation
        m_CurrentFrame = newFrameIndex
        If (m_CurrentFrame < 0) Then m_CurrentFrame = 0
        If (m_CurrentFrame >= m_FrameCount) Then m_CurrentFrame = m_FrameCount - 1
        UpdateAnimationSettings PDImages.GetActiveImage, newFrameIndex
        RenderAnimationFrame
    End If
End Sub

'Play the current animation
Public Sub PlayAnimation()
    
    'Start by updating our animation frame internals (e.g. pulling thumbnails from all layers)
    UpdateAnimationSettings PDImages.GetActiveImage
    
    'Failsafe check
    If (Not m_Animated) Then Exit Sub
    
    'Reset the current animation frame, as necessary
    If (m_CurrentFrame >= m_FrameCount - 1) Then m_CurrentFrame = 0
    
    'Next, we're gonna prep a timer object based on the required delay for this animation frame.
    ' (Note that Windows does not support timer accuracy below 10 ms, so we lock our timer
    ' requests to never be less than 10ms.)
    Dim targetDelayMS As Long
    targetDelayMS = m_Frames(m_CurrentFrame).afFrameDelayMS
    If (targetDelayMS < 10) Then targetDelayMS = 10
        
    m_Timer.Interval = targetDelayMS
    m_Timer.StartTimer
    
    'Render the current frame, then exit
    VBHacks.GetHighResTimeInMS m_TimeAtLastFrame
    RenderAnimationFrame
    m_CurrentFrame = m_CurrentFrame + 1

End Sub

Public Sub StopAnimation()
    If m_Timer.IsActive Then RaiseEvent AnimationEnded
    m_Timer.StopTimer
    m_ExpectedTimeToDisplay = 0
End Sub

'Given an (x, y) coordinate in the navigator, scroll to the matching (x, y) in the image.
Private Sub ScrollToXY(ByVal x As Single, ByVal y As Single)

    'Make sure the image region has been successfully created, or this is all for naught
    If PDImages.IsImageActive() And (m_ImageRegion.Width <> 0!) And (m_ImageRegion.Height <> 0!) Then
    
        'Convert the (x, y) to the [0, 1] range
        Dim xRatio As Double, yRatio As Double
        xRatio = (x - m_ImageRegion.Left) / m_ImageRegion.Width
        yRatio = (y - m_ImageRegion.Top) / m_ImageRegion.Height
        If (xRatio < 0#) Then xRatio = 0#: If (xRatio > 1#) Then xRatio = 1#
        If (yRatio < 0#) Then yRatio = 0#: If (yRatio > 1#) Then yRatio = 1#
        
        'Next, convert those to the (min, max) scale of the current viewport scrollbars
        Dim hScrollRange As Double, vScrollRange As Double, newHScroll As Double, newVscroll As Double
        hScrollRange = FormMain.MainCanvas(0).GetScrollMax(pdo_Horizontal) - FormMain.MainCanvas(0).GetScrollMin(pdo_Horizontal)
        vScrollRange = FormMain.MainCanvas(0).GetScrollMax(pdo_Vertical) - FormMain.MainCanvas(0).GetScrollMin(pdo_Vertical)
        newHScroll = (xRatio * hScrollRange) + FormMain.MainCanvas(0).GetScrollMin(pdo_Horizontal)
        newVscroll = (yRatio * vScrollRange) + FormMain.MainCanvas(0).GetScrollMin(pdo_Vertical)
        
        'Assign the new scrollbar values, then request a viewport refresh
        FormMain.MainCanvas(0).SetRedrawSuspension True
        FormMain.MainCanvas(0).SetScrollValue pdo_Horizontal, newHScroll
        FormMain.MainCanvas(0).SetScrollValue pdo_Vertical, newVscroll
        FormMain.MainCanvas(0).SetRedrawSuspension False
        
        ViewportEngine.Stage2_CompositeAllLayers PDImages.GetActiveImage(), FormMain.MainCanvas(0)
        
        'Notify external UI elements of the change
        FormMain.MainCanvas(0).RelayViewportChanges
        
    End If

End Sub

Private Sub ucSupport_RepaintRequired(ByVal updateLayoutToo As Boolean)
    If updateLayoutToo Then UpdateControlLayout Else RedrawBackBuffer
End Sub

Private Sub UserControl_Initialize()
    
    'Initialize a master user control support class
    Set ucSupport = New pdUCSupport
    ucSupport.RegisterControl UserControl.hWnd, True
    ucSupport.RequestExtraFunctionality True
    ucSupport.SubclassCustomMessage WM_PD_COLOR_MANAGEMENT_CHANGE, True
    
    'Prep the color manager and load default colors
    Set m_Colors = New pdThemeColors
    Dim colorCount As PDNAVINNER_COLOR_LIST: colorCount = [_Count]
    m_Colors.InitializeColorList "PDNavInner", colorCount
    If Not PDMain.IsProgramRunning() Then UpdateColorList
    
    'If the program is running, create our animation timer
    If PDMain.IsProgramRunning() Then Set m_Timer = New pdTimer
    
End Sub

'At run-time, painting is handled by the support class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    ucSupport.RequestIDERepaint UserControl.hDC
End Sub

Private Sub UserControl_Resize()
    If Not PDMain.IsProgramRunning() Then ucSupport.RequestRepaint True
End Sub

'Call this to recreate all buffers against a changed control size.
Private Sub UpdateControlLayout()
    
    'Retrieve DPI-aware control dimensions from the support class
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'Whenever the navigator is resized, we must also resize the image thumbnail to match.
    
    'At present, we pad the thumbnail by a few pixels so we have room for a border.
    Dim thumbWidth As Long, thumbHeight As Long
    thumbWidth = bWidth - Interface.FixDPIFloat(THUMB_PADDING) * 2
    thumbHeight = bHeight - Interface.FixDPIFloat(THUMB_PADDING) * 2
    
    'Try to optimize re-creating the thumbnail, so we only do it when absolutely necessary
    If (m_ImageThumbnail Is Nothing) Then Set m_ImageThumbnail = New pdDIB
    If (m_ImageThumbnail.GetDIBWidth <> thumbWidth) Or (m_ImageThumbnail.GetDIBHeight <> thumbHeight) Then
        m_ImageThumbnail.CreateBlank thumbWidth, thumbHeight, 32, 0, 0
    Else
        m_ImageThumbnail.ResetDIB 0
    End If
    
    Dim tmpImage As pdImage
    RaiseEvent RequestUpdatedThumbnail(m_ImageThumbnail, m_ThumbEventX, m_ThumbEventY, tmpImage)
    
    If (tmpImage Is Nothing) Or (m_ImageThumbnail Is Nothing) Then
        EndAnimations
        m_LastImageID = vbNullString
    Else
        StopAnimation
        Dim lastImageID As String
        lastImageID = m_LastImageID
        m_LastImageID = tmpImage.GetUniqueID()
    End If
    
    'Update animation parameters, as necessary
    If (LenB(m_LastImageID) = 0) Or (lastImageID <> m_LastImageID) Or (m_LastThumbWidth <> thumbWidth) Or (m_LastThumbHeight <> thumbHeight) Then
        If (Not tmpImage Is Nothing) Then m_Animated = tmpImage.IsAnimated()
        If m_Animated Then UpdateAnimationSettings tmpImage, m_CurrentFrame, True
    End If
    
    m_LastThumbWidth = thumbWidth
    m_LastThumbHeight = thumbHeight
    
    'On new image loads, reset the current frame to 0
    If (lastImageID <> m_LastImageID) Then
        StopAnimation
        m_CurrentFrame = 0
        RaiseEvent AnimationFrameChanged(m_CurrentFrame)
    End If
    
    'With the backbuffer and image thumbnail successfully created, we can finally redraw the new navigator window
    RedrawBackBuffer
    
End Sub

Private Sub EndAnimations()
    m_Animated = False
    StopAnimation
End Sub

'After the thumbnail has received an "update" request, we also need to update our animation frames
Private Sub UpdateAnimationSettings(ByRef srcImage As pdImage, Optional ByVal forciblyUpdateIndex As Long = -1, Optional ByVal fastUpdate As Boolean = False)
    
    If ((srcImage Is Nothing) Or (m_ImageThumbnail Is Nothing)) Then
        m_Animated = False
        StopAnimation
        Exit Sub
    End If
    
    m_DoNotRenderAnimation = True
    
    m_Animated = srcImage.IsAnimated()
    
    If m_Animated Then
    
        'Load all animation frames.
        If (m_FrameCount <> srcImage.GetNumOfLayers()) Then
            m_FrameCount = srcImage.GetNumOfLayers
            ReDim m_Frames(0 To m_FrameCount - 1) As PD_AnimationFrame
        End If
        
        'Retrieving thumbnails uses the same math as the regular thumbnail; in animation files,
        ' we assume all frames are the same size as the image itself, because this is how
        ' PD pre-processes them.  (This may change in the future.)
        Dim bWidth As Long, bHeight As Long
        bWidth = ucSupport.GetBackBufferWidth
        bHeight = ucSupport.GetBackBufferHeight
        
        'The thumbDIB passed to this function will always be sized to the largest size the navigator can physically support.
        ' Our job is to place a composited copy of the current image inside that DIB, automatically centered as necessary.
        Dim thumbSize As Long
        Dim thumbImageWidth As Long, thumbImageHeight As Long
        PDMath.ConvertAspectRatio PDImages.GetActiveImage.Width, PDImages.GetActiveImage.Height, m_ImageThumbnail.GetDIBWidth, m_ImageThumbnail.GetDIBHeight, thumbImageWidth, thumbImageHeight
        
        'Ensure the thumb isn't larger than the actual image
        If (thumbImageWidth > PDImages.GetActiveImage.Width) Or (thumbImageHeight > PDImages.GetActiveImage.Height) Then
            thumbImageWidth = PDImages.GetActiveImage.Width
            thumbImageHeight = PDImages.GetActiveImage.Height
        End If
        
        'Store the boundary rect of where the thumb will actually appear; we need this for rendering
        ' a transparency checkerboard
        With m_AniThumbBounds
            .Left = (bWidth * 0.5) - (thumbImageWidth * 0.5)
            .Top = (bHeight * 0.5) - (thumbImageHeight * 0.5)
            .Width = thumbImageWidth
            .Height = thumbImageHeight
        End With
        
        'Use the larger dimension to construct the thumb.  (For simplicity, thumbs are always square.)
        If (thumbImageWidth > thumbImageHeight) Then thumbSize = thumbImageWidth Else thumbSize = thumbImageHeight
        
        Dim xThumb As Long, yThumb As Long
        xThumb = (bWidth * 0.5) - (thumbSize * 0.5)
        yThumb = (bHeight * 0.5) - (thumbSize * 0.5)
        
        'Load all thumbnails
        Dim i As Long, loopStart As Long, loopEnd As Long
        loopStart = 0
        loopEnd = m_FrameCount - 1
        
        If fastUpdate And (forciblyUpdateIndex >= 0) Then
            loopStart = forciblyUpdateIndex
            loopEnd = forciblyUpdateIndex
        End If
            
        For i = loopStart To loopEnd
            
            Dim needToUpdate As Boolean
            needToUpdate = False
            If (Not m_Frames(i).afDIB Is Nothing) Then needToUpdate = (m_Frames(i).afDIB.GetDIBWidth <> thumbSize)
            If (Not needToUpdate) Then needToUpdate = (m_Frames(i).afTimeStamp <> srcImage.GetLayerByIndex(i).GetTimeOfLastChange())
            
            If (i = forciblyUpdateIndex) Or needToUpdate Then
                
                m_Frames(i).afTimeStamp = srcImage.GetLayerByIndex(i).GetTimeOfLastChange()
                
                'Retrieve an updated thumbnail
                If (m_Frames(i).afDIB Is Nothing) Then Set m_Frames(i).afDIB = New pdDIB
                m_Frames(i).afDIB.CreateBlank thumbSize, thumbSize, 32, 0, 0
                
                m_Frames(i).afOffsetX = xThumb
                m_Frames(i).afOffsetY = yThumb
                srcImage.GetLayerByIndex(i).RequestThumbnail m_Frames(i).afDIB, thumbSize, True
                
            End If
            
            'Retrieve layer frame times
            m_Frames(i).afFrameDelayMS = Animation.GetFrameTimeFromLayerName(srcImage.GetLayerByIndex(i).GetLayerName())
            
        Next i
    
    Else
        StopAnimation
    End If
    
    m_DoNotRenderAnimation = False
    RenderAnimationFrame
    
End Sub

'Need to redraw the navigator box?  Call this.  Note that it *does not* request a new image thumbnail.  You must handle
' that separately.  This simply uses whatever's been previously cached.
Private Sub RedrawBackBuffer(Optional ByVal skipAnimationStep As Boolean = False)
    
    'If the current image is animated, use the separate animation-specific render function
    If m_Animated And (Not skipAnimationStep) Then
        If (m_CurrentFrame < 0) Then m_CurrentFrame = 0
        If (m_CurrentFrame >= m_FrameCount) Then m_CurrentFrame = m_FrameCount - 1
        RenderAnimationFrame
        Exit Sub
    End If
    
    'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
    Dim bufferDC As Long
    bufferDC = ucSupport.GetBackBufferDC(True, m_Colors.RetrieveColor(PDNI_Background, Me.Enabled))
    If (bufferDC = 0) Then Exit Sub
    
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    If PDMain.IsProgramRunning() Then
    
        'TODO: move rect calculation into a previous step
        
        'If an image has been loaded, determine a centered position for the image's thumbnail
        If (Not PDImages.IsImageActive()) Then
            With m_ThumbRect
                .Width = 0
                .Height = 0
                .Left = 0
                .Top = 0
            End With
        Else
            
            With m_ThumbRect
                .Width = m_ImageThumbnail.GetDIBWidth
                .Height = m_ImageThumbnail.GetDIBHeight
                .Left = (bWidth - m_ImageThumbnail.GetDIBWidth) * 0.5
                .Top = (bHeight - m_ImageThumbnail.GetDIBHeight) * 0.5
            End With
            
            'Offset that top-left corner by the thumbnail's position, and cache it to a module-level rect so we can use
            ' it for hit-detection during mouse events.
            With m_ImageRegion
                .Left = m_ThumbRect.Left + m_ThumbEventX
                .Top = m_ThumbRect.Top + m_ThumbEventY
                .Width = m_ImageThumbnail.GetDIBWidth - (m_ThumbEventX * 2#)
                .Height = m_ImageThumbnail.GetDIBHeight - (m_ThumbEventY * 2#)
            End With
            
            'Paint a checkerboard background only over the relevant image region
            With m_ImageRegion
                GDI_Plus.GDIPlusFillDIBRect_Pattern Nothing, .Left, .Top, .Width, .Height, g_CheckerboardPattern, bufferDC, True
            End With
            
            'Paint the thumb rect without regard for the image region (as it will always be a square)
            With m_ThumbRect
                GDI_Plus.GDIPlus_StretchBlt Nothing, .Left, .Top, .Width, .Height, m_ImageThumbnail, 0, 0, .Width, .Height, , GP_IM_HighQualityBicubic, bufferDC
                m_ImageThumbnail.FreeFromDC
            End With
                        
            'Query the active image for a copy of the intersection rect of the viewport, and the image itself,
            ' in image coordinate space
            Dim viewportRect As RectF
            If (PDImages.GetActiveImage.ImgViewport Is Nothing) Then Exit Sub
            PDImages.GetActiveImage.ImgViewport.GetIntersectRectImage viewportRect
            
            'We now want to convert the viewport rect into our little navigator coordinate space.  Start by converting the
            ' viewport dimensions to a 1-based system, relative to the original image's width and height.
            If (PDImages.GetActiveImage.Width > 0) And (PDImages.GetActiveImage.Height > 0) Then
                
                Dim widthDivisor As Double, heightDivisor As Double
                widthDivisor = 1# / PDImages.GetActiveImage.Width
                heightDivisor = 1# / PDImages.GetActiveImage.Height
                
                Dim relativeRect As RectF
                With relativeRect
                    .Left = viewportRect.Left * widthDivisor
                    .Top = viewportRect.Top * heightDivisor
                    .Width = viewportRect.Width * widthDivisor
                    .Height = viewportRect.Height * heightDivisor
                    
                    'Next, scale those 1-based values by the navigator's current size
                    .Left = .Left * m_ImageRegion.Width
                    .Top = .Top * m_ImageRegion.Height
                    .Width = .Width * m_ImageRegion.Width
                    .Height = .Height * m_ImageRegion.Height
                    
                    'Finally, scale the values by the offsets of the image region
                    .Left = .Left + m_ImageRegion.Left
                    .Top = .Top + m_ImageRegion.Top
                End With
                
                'If the mouse is inside the control, figure out if the last mouse coordinates are inside the region box.
                ' If they are, we want to highlight it.
                Dim useHighlightColor As Boolean
                
                If m_MouseInsideBox Then
                    useHighlightColor = PDMath.IsPointInRectF(m_LastMouseX, m_LastMouseY, relativeRect)
                Else
                    useHighlightColor = False
                End If
                
                'Draw a canvas-style border around the relevant viewport rect
                GDI_Plus.GDIPlusDrawCanvasRectF bufferDC, relativeRect, , useHighlightColor
                
            End If
            
        End If
    
    End If
    
    'Paint the final result to the screen, as relevant
    ucSupport.RequestRepaint
    
End Sub

'Render the current animation frame
Private Sub RenderAnimationFrame()
    
    If m_DoNotRenderAnimation Then Exit Sub
    
    'Make sure the frame request is valid; if it isn't, exit immediately
    If (m_CurrentFrame >= 0) And (m_CurrentFrame < m_FrameCount) Then
        
        'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
        Dim bufferDC As Long
        bufferDC = ucSupport.GetBackBufferDC(True, m_Colors.RetrieveColor(PDNI_Background, Me.Enabled))
        If (bufferDC = 0) Then Exit Sub
        
        Dim bWidth As Long, bHeight As Long
        bWidth = ucSupport.GetBackBufferWidth
        bHeight = ucSupport.GetBackBufferHeight
        
        If PDMain.IsProgramRunning() Then
            
            'Paint a checkerboard background only over the relevant image region, followed by the frame itself
            With m_Frames(m_CurrentFrame)
                GDI_Plus.GDIPlusFillDIBRect_Pattern Nothing, m_AniThumbBounds.Left, m_AniThumbBounds.Top, m_AniThumbBounds.Width, m_AniThumbBounds.Height, g_CheckerboardPattern, bufferDC, True
                GDI_Plus.GDIPlus_StretchBlt Nothing, (bWidth - .afDIB.GetDIBWidth) * 0.5, (bHeight - .afDIB.GetDIBHeight) * 0.5, .afDIB.GetDIBWidth, .afDIB.GetDIBHeight, .afDIB, 0, 0, .afDIB.GetDIBWidth, .afDIB.GetDIBHeight, , GP_IM_HighQualityBicubic, bufferDC
                .afDIB.FreeFromDC
            End With
            
        End If
        
        'Paint the final result to the screen, as relevant
        ucSupport.RequestRepaint True
    
    'If our frame counter is invalid, end all animations
    Else
        StopAnimation
    End If
        
End Sub

'Call this when a new thumbnail needs to be set.  The class will reset its thumb DIB to match its current size, then raise
' a RequestUpdatedThumbnail function.
Public Sub NotifyNewThumbNeeded()
    UpdateControlLayout
End Sub

'Call this when the viewport position has changed.  This function operates independently of the NotifyNewThumbNeeded() function,
' because the viewport and thumbnail are unlikely to change simultaneously.
Public Sub NotifyNewViewportPosition()
    
    'Skip viewport-based redraws when the navigator is actively animating
    If (Not m_Timer.IsActive) Then RedrawBackBuffer
    
End Sub

'Before this control does any painting, we need to retrieve relevant colors from PD's primary theming class.  Note that this
' step must also be called if/when PD's visual theme settings change.
Private Sub UpdateColorList()
    m_Colors.LoadThemeColor PDNI_Background, "Background", IDE_WHITE
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog,
' and/or retranslating any text against the current language.
Public Sub UpdateAgainstCurrentTheme(Optional ByVal hostFormhWnd As Long = 0)
    If ucSupport.ThemeUpdateRequired Then
        UpdateColorList
        If PDMain.IsProgramRunning() Then NavKey.NotifyControlLoad Me, hostFormhWnd
        If PDMain.IsProgramRunning() Then ucSupport.UpdateAgainstThemeAndLanguage
    End If
End Sub

'By design, PD prefers to not use design-time tooltips.  Apply tooltips at run-time, using this function.
' (IMPORTANT NOTE: translations are handled automatically.  Always pass the original English text!)
Public Sub AssignTooltip(ByRef newTooltip As String, Optional ByRef newTooltipTitle As String = vbNullString, Optional ByVal raiseTipsImmediately As Boolean = False)
    ucSupport.AssignTooltip UserControl.ContainerHwnd, newTooltip, newTooltipTitle, raiseTipsImmediately
End Sub
