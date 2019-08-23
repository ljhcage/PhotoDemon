VERSION 5.00
Begin VB.UserControl pdNavigator 
   BackColor       =   &H80000005&
   ClientHeight    =   2370
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4830
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
   ScaleHeight     =   158
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   322
   ToolboxBitmap   =   "pdNavigator.ctx":0000
   Begin PhotoDemon.pdContainer pnlAnimation 
      Height          =   375
      Left            =   0
      TabIndex        =   1
      Top             =   1560
      Visible         =   0   'False
      Width           =   4815
      _ExtentX        =   8493
      _ExtentY        =   661
      Begin PhotoDemon.pdButtonToolbox btnPlay 
         Height          =   375
         Index           =   0
         Left            =   0
         TabIndex        =   2
         Top             =   0
         Width           =   375
         _ExtentX        =   661
         _ExtentY        =   661
         DontHighlightDownState=   -1  'True
         StickyToggle    =   -1  'True
      End
      Begin PhotoDemon.pdButtonToolbox btnPlay 
         Height          =   375
         Index           =   1
         Left            =   480
         TabIndex        =   3
         Top             =   0
         Width           =   375
         _ExtentX        =   661
         _ExtentY        =   661
         DontHighlightDownState=   -1  'True
         StickyToggle    =   -1  'True
      End
      Begin PhotoDemon.pdSliderStandalone sldFrame 
         Height          =   375
         Left            =   960
         TabIndex        =   4
         Top             =   0
         Width           =   3855
         _ExtentX        =   6800
         _ExtentY        =   661
      End
   End
   Begin PhotoDemon.pdNavigatorInner navInner 
      Height          =   855
      Left            =   120
      TabIndex        =   0
      Top             =   120
      Width           =   1215
      _ExtentX        =   2143
      _ExtentY        =   1508
   End
End
Attribute VB_Name = "pdNavigator"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Navigation custom control
'Copyright 2015-2019 by Tanner Helland
'Created: 16/October/15
'Last updated: 22/August/19
'Last update: overhaul control to support new animation mode
'
'In 7.0, a "navigation" panel was added to the right-side toolbar.  This user control provides the
' actual "navigation" behavior, where the user can click anywhere on the image thumbnail to move the
' viewport over that location.
'
'In 7.2, animation-centric controls were added.  These auto-activate when the underlying image is
' flagged as animate-able (animated GIFs or PNGs, for example).
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

'Because VB focus events are wonky, especially when we use CreateWindow within a UC, this control raises its own
' specialized focus events.  If you need to track focus, use these instead of the default VB functions.
Public Event GotFocusAPI()
Public Event LostFocusAPI()

'If the current parent image is animated, we display additional playback controls
Private m_Animated As Boolean

'To avoid circular updates on animation state changes, we use this tracker
Private m_DoNotUpdate As Boolean

'User control support class.  Historically, many classes (and associated subclassers) were required by each user control,
' but I've since attempted to wrap these into a single master control support class.
Private WithEvents ucSupport As pdUCSupport
Attribute ucSupport.VB_VarHelpID = -1

'Local list of themable colors.  This list includes all potential colors used by this class, regardless of state change
' or internal control settings.  The list is updated by calling the UpdateColorList function.
' (Note also that this list does not include variants, e.g. "BorderColor" vs "BorderColor_Hovered".  Variant values are
'  automatically calculated by the color management class, and they are retrieved by passing boolean modifiers to that
'  class, rather than treating every imaginable variant as a separate constant.)
Private Enum PDNAVIGATOR_COLOR_LIST
    [_First] = 0
    PDN_Background = 0
    [_Last] = 0
    [_Count] = 1
End Enum

'Color retrieval and storage is handled by a dedicated class; this allows us to optimize theme interactions,
' without worrying about the details locally.
Private m_Colors As pdThemeColors

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_Navigator
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
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

Private Sub btnPlay_Click(Index As Integer)

    Select Case Index
        
        'Play/pause
        Case 0
            If btnPlay(0).Value Then navInner.PlayAnimation Else navInner.StopAnimation
            
        '1x/repeat
        Case 1
            navInner.SetAnimationRepeat btnPlay(Index).Value
    
    End Select
    
    UpdateButtonTooltips

End Sub

Private Sub navInner_AnimationEnded()
    m_DoNotUpdate = True
        If btnPlay(0).Value Then btnPlay(0).Value = False
        sldFrame.Value = navInner.GetCurrentFrame()
    m_DoNotUpdate = False
End Sub

Private Sub navInner_AnimationFrameChanged(ByVal newFrameIndex As Long)
    m_DoNotUpdate = True
    sldFrame.Value = newFrameIndex
    m_DoNotUpdate = False
End Sub

Private Sub navInner_NewViewportLocation(ByVal imgX As Single, ByVal imgY As Single)
    RaiseEvent NewViewportLocation(imgX, imgY)
End Sub

Private Sub navInner_RequestUpdatedThumbnail(thumbDIB As pdDIB, thumbX As Single, thumbY As Single, ByRef srcImage As pdImage)
    
    RaiseEvent RequestUpdatedThumbnail(thumbDIB, thumbX, thumbY, srcImage)
    
    If (srcImage Is Nothing) Then
        If m_Animated Then
            m_Animated = False
            UpdateControlLayout
        End If
    Else
        If (srcImage.IsAnimated <> m_Animated) Then
            m_Animated = srcImage.IsAnimated
            UpdateControlLayout
        End If
    End If
    
    'Update any animation controls, as relevant
    If m_Animated Then
        m_DoNotUpdate = True
        sldFrame.Min = 0
        sldFrame.Max = PDImages.GetActiveImage.GetNumOfLayers - 1
        m_DoNotUpdate = False
    End If
    
End Sub

Private Sub sldFrame_Change()
    If (Not m_DoNotUpdate) Then navInner.ChangeActiveFrame sldFrame.Value
    UpdateSliderTooltip
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

Private Sub ucSupport_RepaintRequired(ByVal updateLayoutToo As Boolean)
    If updateLayoutToo Then UpdateControlLayout Else RedrawBackBuffer
End Sub

Private Sub UserControl_Initialize()
    
    'Initialize a master user control support class
    Set ucSupport = New pdUCSupport
    ucSupport.RegisterControl UserControl.hWnd, False
    ucSupport.RequestExtraFunctionality True
    
    'Prep the color manager and load default colors
    Set m_Colors = New pdThemeColors
    Dim colorCount As PDNAVIGATOR_COLOR_LIST: colorCount = [_Count]
    m_Colors.InitializeColorList "PDNavigator", colorCount
    If Not PDMain.IsProgramRunning() Then UpdateColorList
    
    'Set default animation status
    m_Animated = False
    
End Sub

'At run-time, painting is handled by the support class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    ucSupport.RequestIDERepaint UserControl.hDC
End Sub

Private Sub UserControl_Resize()
    If Not PDMain.IsProgramRunning() Then ucSupport.RequestRepaint True
End Sub

'Call this when a new thumbnail needs to be set.  The class will reset its thumb DIB to match its current size, then raise
' a RequestUpdatedThumbnail function.
Public Sub NotifyNewThumbNeeded()
    navInner.NotifyNewThumbNeeded
End Sub

'Call this when the viewport position has changed.  This function operates independently of the NotifyNewThumbNeeded() function,
' because the viewport and thumbnail are unlikely to change simultaneously.
Public Sub NotifyNewViewportPosition()
    navInner.NotifyNewViewportPosition
End Sub

'Call this to recreate all buffers against a changed control size.
Private Sub UpdateControlLayout()
    
    'Retrieve DPI-aware control dimensions from the support class
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'If the current image is animated, we need to display additional animation controls
    If m_Animated Then
        
        'Move the animation panel to the bottom of the navigator area
        pnlAnimation.SetPositionAndSize 0, bHeight - pnlAnimation.GetHeight, bWidth, pnlAnimation.GetHeight
        
        'Move the "repeat" button to the right side of the panel
        btnPlay(1).SetLeft pnlAnimation.GetWidth - btnPlay(1).GetWidth
        
        'Extend the frame scroller between the two buttons
        sldFrame.SetLeft btnPlay(0).GetLeft + btnPlay(0).GetWidth + Interface.FixDPI(4)
        sldFrame.SetWidth (btnPlay(1).GetLeft - Interface.FixDPI(4)) - sldFrame.GetLeft
        
        'Extend the regular navigation control to the top of the panel, then display both
        navInner.SetPositionAndSize 0, 0, bWidth, (bHeight - pnlAnimation.GetHeight) - 1
        pnlAnimation.Visible = True
        
    'For non-animated images, sync the navigator box to the full size of the control
    Else
        pnlAnimation.Visible = False
        navInner.SetPositionAndSize 0, 0, bWidth, bHeight
    End If
    
    'With the backbuffer and image thumbnail successfully created, we can finally redraw the new navigator window
    RedrawBackBuffer
    
End Sub

'Need to redraw the navigator box?  Call this.  Note that it *does not* request a new image thumbnail.  You must handle
' that separately.  This simply uses whatever's been previously cached.
Private Sub RedrawBackBuffer()
    
    'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
    Dim bufferDC As Long
    bufferDC = ucSupport.GetBackBufferDC(True, m_Colors.RetrieveColor(PDN_Background, Me.Enabled))
    If (bufferDC = 0) Then Exit Sub
    
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'Paint the final result to the screen, as relevant
    ucSupport.RequestRepaint
    
End Sub

'Before this control does any painting, we need to retrieve relevant colors from PD's primary theming class.  Note that this
' step must also be called if/when PD's visual theme settings change.
Private Sub UpdateColorList()
    m_Colors.LoadThemeColor PDN_Background, "Background", IDE_WHITE
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog,
' and/or retranslating any text against the current language.
Public Sub UpdateAgainstCurrentTheme(Optional ByVal hostFormhWnd As Long = 0)
    
    If ucSupport.ThemeUpdateRequired Then
        
        UpdateColorList
        If PDMain.IsProgramRunning() Then ucSupport.UpdateAgainstThemeAndLanguage
        
        'Also update child controls
        navInner.UpdateAgainstCurrentTheme
        pnlAnimation.UpdateAgainstCurrentTheme
        sldFrame.UpdateAgainstCurrentTheme
        
        Dim i As Long
        For i = btnPlay.lBound To btnPlay.UBound
            btnPlay(i).UpdateAgainstCurrentTheme
        Next i
        
        'Create new runtime button icons
        CreateButtonIcons
        
        'Update tooltips
        UpdateButtonTooltips
        UpdateSliderTooltip
        
    End If
    
End Sub

Private Sub UpdateButtonTooltips()
    
    If btnPlay(0).Value Then
        btnPlay(0).AssignTooltip "Pause the current animation"
    Else
        btnPlay(0).AssignTooltip "Play the current animation"
    End If
    
    btnPlay(1).AssignTooltip "Toggle between 1x and repeating previews"
    
End Sub

Private Sub UpdateSliderTooltip()
    If (Not g_Language Is Nothing) And PDImages.IsImageActive Then
        Dim frameToolText As String
        frameToolText = g_Language.TranslateMessage("Current frame: %1", PDImages.GetActiveImage.GetLayerByIndex(sldFrame.Value).GetLayerName)
        sldFrame.AssignTooltip frameToolText
    End If
End Sub

'Some button icons on this page are created dynamically at run-time
Private Sub CreateButtonIcons()

    'Play and pause icons are generated at run-time, using the current UI accent color
    
    Dim btnIconSize As Long
    btnIconSize = btnPlay(0).GetWidth - Interface.FixDPI(4)
    
    Dim cSurface As pd2DSurface, cPen As pd2DPen, cBrush As pd2DBrush
    
    Dim icoPlay As pdDIB
    Set icoPlay = New pdDIB
    icoPlay.CreateBlank btnIconSize, btnIconSize, 32, 0, 0
    icoPlay.SetInitialAlphaPremultiplicationState True
    
    'Play icon first
    Drawing2D.QuickCreateSurfaceFromDIB cSurface, icoPlay, True
    cSurface.SetSurfacePixelOffset P2_PO_Half
    
    'Do a little coordinate math to automatically calculate a triangle or double-bar pause vector
    Dim cPath As pd2DPath
    Set cPath = New pd2DPath
    
    Dim cPoints() As PointFloat
    
    Dim cx As Single, cy As Single
    cx = btnIconSize * 0.5
    cy = btnIconSize * 0.5
    
    Dim cRadius As Single
    cRadius = (btnIconSize * 0.35)
    
    ReDim cPoints(0 To 2) As PointFloat
    cPoints(0).x = cx + cRadius
    cPoints(0).y = cy
    
    PDMath.RotatePointAroundPoint cPoints(0).x, cPoints(0).y, cx, cy, (2# * PI) / 3#, cPoints(1).x, cPoints(1).y
    PDMath.RotatePointAroundPoint cPoints(0).x, cPoints(0).y, cx, cy, -1 * (2# * PI) / 3#, cPoints(2).x, cPoints(2).y
    
    cPath.AddLines 3, VarPtr(cPoints(0))
    cPath.CloseCurrentFigure
    
    'Re-center the path (as the triangle will be biased rightward due to the angles used)
    cPath.TranslatePath -1! * (cRadius - (cx - cPoints(1).x)) * 0.5, 0!
    
    Drawing2D.QuickCreateSolidBrush cBrush, g_Themer.GetGenericUIColor(UI_Accent)
    PD2D.FillPath cSurface, cBrush, cPath
    
    'Next, a pause icon
    Dim icoPause As pdDIB
    Set icoPause = New pdDIB
    icoPause.CreateBlank btnIconSize, btnIconSize, 32, 0, 0
    icoPause.SetInitialAlphaPremultiplicationState True
    
    'Set cSurface = Nothing
    Drawing2D.QuickCreateSurfaceFromDIB cSurface, icoPause, True
    cSurface.SetSurfacePixelOffset P2_PO_Half
    
    ReDim cPoints(0 To 3) As PointFloat
    cPoints(0).x = (btnIconSize * 0.33)
    cPoints(0).y = (btnIconSize * 0.2)
    cPoints(1).x = cPoints(0).x
    cPoints(1).y = btnIconSize - cPoints(0).y
    
    cPoints(2).x = btnIconSize - cPoints(0).x
    cPoints(2).y = cPoints(0).y
    cPoints(3).x = cPoints(2).x
    cPoints(3).y = cPoints(1).y
    
    cPath.ResetPath
    cPath.AddLines 2, VarPtr(cPoints(0))
    cPath.CloseCurrentFigure
    cPath.AddLines 2, VarPtr(cPoints(2))
    cPath.CloseCurrentFigure
    
    Drawing2D.QuickCreateSolidPen cPen, btnIconSize * 0.15, g_Themer.GetGenericUIColor(UI_Accent)
    PD2D.DrawPath cSurface, cPen, cPath
        
    'Clear all drawing objects
    Set cSurface = Nothing: Set cPen = Nothing: Set cBrush = Nothing
    
    'Assign the icons
    btnPlay(0).AssignImage vbNullString, icoPlay
    btnPlay(0).AssignImage_Pressed vbNullString, icoPause
    
    'The 1x/repeat icons use prerendered graphics
    btnIconSize = btnIconSize - 4
    Dim tmpDIB As pdDIB
    If g_Resources.LoadImageResource("1x", tmpDIB, btnIconSize, btnIconSize, , False, g_Themer.GetGenericUIColor(UI_Accent)) Then btnPlay(1).AssignImage vbNullString, tmpDIB
    If g_Resources.LoadImageResource("infinity", tmpDIB, btnIconSize, btnIconSize, , False, g_Themer.GetGenericUIColor(UI_Accent)) Then btnPlay(1).AssignImage_Pressed vbNullString, tmpDIB
    
End Sub

'By design, PD prefers to not use design-time tooltips.  Apply tooltips at run-time, using this function.
' (IMPORTANT NOTE: translations are handled automatically.  Always pass the original English text!)
Public Sub AssignTooltip(ByRef newTooltip As String, Optional ByRef newTooltipTitle As String = vbNullString, Optional ByVal raiseTipsImmediately As Boolean = False)
    ucSupport.AssignTooltip UserControl.ContainerHwnd, newTooltip, newTooltipTitle, raiseTipsImmediately
End Sub
