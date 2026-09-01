{*******************************************************************************
  Neslib.SokolCustomThreadedBase v0.1
********************************************************************************
  A high-performance, threaded Delphi component that seamlessly integrates
  Neslib.Sokol into VCL applications without blocking the UI thread.

  Author:  Lara Miriam Tamy Reschke / LamitaOne
  License: MIT

  ----------------------------------------------------------------------------
  ARCHITECTURE & DESIGN
  ----------------------------------------------------------------------------
  1. Neslib.Sokol Lifecycle Integration:
     Neslib.Sokol.App manages its own window and message loop via TApplication.
     Trying to force TApplication into a background thread directly causes
     assertion failures (_sg.valid) because the graphics backend isn't
     initialized.
     To solve this, this component inherits from TSampleApp (the official
     Neslib base class for samples). TSampleApp correctly handles the TGfx
     setup internally. We just override Init, Frame, and Cleanup to inject
     our own logic and timing.

  2. Hybrid High-Resolution Timer:
     Sokol's internal loop is limited by V-Sync by default. We explicitly
     disable V-Sync (SwapInterval = 0) to uncap the framerate.
     To maintain a specific target FPS without burning 100% CPU, we use a
     hybrid wait strategy:
     - Sleep(0) yields CPU time to other threads while far from target.
     - A tight spinlock for the last ~0.5ms to ensure frame-perfect timing
       without context switching overhead.

  3. Thread-Safe VCL Integration:
     The Sokol Window is created and runs entirely in a background TThread.
     The VCL UI (buttons, trackbars) remains 100% responsive. Setting
     Active = True starts the thread and the loop; setting it to False
     pauses the logic updates without destroying the window.
*******************************************************************************}

unit uSokolCustomThreadedBase;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.SyncObjs, System.Diagnostics,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  Winapi.Windows,
  Neslib.Sokol.App,
  Neslib.Sokol.Gfx,
  Neslib.Sokol.Api,
  Neslib.Sokol.gl,
  Neslib.Sokol.Glue,
  SampleApp; // Required! TSampleApp handles the complex Neslib GFX backend setup.

const
  // Threshold for the spinlock phase in nanoseconds (0.5 ms).
  // A lower value reduces CPU usage but might introduce minor frame jitter.
  SPIN_THRESHOLD_NS = 500000;

type
  {------------------------------------------------------------------------------
    THighResTimer
    A record providing high-precision frame timing with a hybrid wait strategy
    to balance accuracy and CPU usage.
  ------------------------------------------------------------------------------}
  THighResTimer = record
  private
    FSW: TStopwatch;
  public
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  { Simple 3D Vector record for demo math }
  TVec3 = record
    x, y, z: Single;
  end;

  TSokolCustomThreadedBase = class;

  {------------------------------------------------------------------------------
    TSokolThreadedApp
    Inherits from TSampleApp to ensure Neslib's internal GFX backend is
    initialized correctly before we attempt to use sglSetup.
  ------------------------------------------------------------------------------}
  TSokolThreadedApp = class(TSampleApp)
  private
    FOwner: TSokolCustomThreadedBase;
    FTimer: THighResTimer;
    FFreq, FFrameTicks: Int64;
    FNextFrame, FNowTicks, FLastFrameTicks, FLastFpsTime: Int64;
    FDeltaSec, FTimeSec: Double;
    FFrameCount: Integer;
    FPassAction: TPassAction;
    FConfigTitle: AnsiString;
  protected
    procedure Configure(var AConfig: TAppConfig); override;
  public
    constructor Create(AOwner: TSokolCustomThreadedBase); reintroduce;
    procedure Init; override;
    procedure Frame; override;
    procedure Cleanup; override;
  end;

  {------------------------------------------------------------------------------
    TSokolCustomThreadedBase
    The main VCL component. Drop this on a form and set Active := True.
  ------------------------------------------------------------------------------}
  TSokolCustomThreadedBase = class(TComponent)
  private
    FThread: TThread;
    FTargetFPS: Integer;
    FThreadActive: Boolean;
    FPaused: Boolean;
    FActive: Boolean;
    FWindowName: AnsiString;
    FInternalApp: TSokolThreadedApp;

    { 3D Demo State }
    FCubePos: TVec3;
    FCubeVel: TVec3;
    FAngle: Single;
    FRealFPS: Integer;

    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure StartThread;
    procedure StopThread;
  protected
    { Override these in derived classes for custom rendering/logic }
    procedure UpdateLogic(const DeltaTime: Double); virtual;
    procedure RenderEffect(const ATime: Double); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    property RealFPS: Integer read FRealFPS;
  published
    property Active: Boolean read FActive write SetActive default False;
    property TargetFPS: Integer read FTargetFPS write SetTargetFPS default 60;
  end;

implementation

{==============================================================================
  THighResTimer Implementation
==============================================================================}

procedure THighResTimer.Init;
begin
  // Start the underlying high-resolution stopwatch
  FSW := TStopwatch.StartNew;
end;

function THighResTimer.GetTicks: Int64;
begin
  // Get raw elapsed ticks for maximum precision
  Result := FSW.ElapsedTicks;
end;

procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  Freq, SpinTicks, Remaining: Int64;
begin
  Freq := TStopwatch.Frequency;
  if Freq = 0 then Exit;

  // Calculate how many ticks correspond to the spin threshold
  SpinTicks := (UInt64(ASpinNanoseconds) * UInt64(Freq)) div 1000000000;

  // Phase 1: OS Sleep. Yield CPU time to other threads while far from target.
  // Using Sleep(0) instead of Sleep(1) for lower latency on modern Windows.
  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    if TThread.CheckTerminated then Exit;
    Sleep(0);
    Remaining := ATargetTicks - GetTicks;
  end;

  // Phase 2: Spinlock. Burn CPU cycles for the last few microseconds to
  // guarantee we hit the exact target tick without context switch latency.
  while GetTicks < ATargetTicks do ;
end;

{==============================================================================
  TSokolThreadedApp Implementation
==============================================================================}

constructor TSokolThreadedApp.Create(AOwner: TSokolCustomThreadedBase);
begin
  FOwner := AOwner;

  // Cache the window title locally to avoid accessing VCL properties during
  // the constructor phase where it might not be fully initialized.
  if FOwner.FWindowName <> '' then
    FConfigTitle := FOwner.FWindowName
  else
    FConfigTitle := 'Sokol Window';

  inherited Create;
end;

procedure TSokolThreadedApp.Configure(var AConfig: TAppConfig);
begin
  inherited;
  AConfig.Width := 800;
  AConfig.Height := 600;
  AConfig.SampleCount := 4; // MSAA 4x

  // PERFORMANCE CRITICAL:
  // We disable V-Sync. Otherwise, TGfx.Commit would block the thread until
  // the monitor refreshes, capping our FPS at 60. We handle timing manually.
  AConfig.SwapInterval := 0;
  AConfig.DisableVSync := True;

  AConfig.WindowTitle := PAnsiChar(FConfigTitle);
end;

procedure TSokolThreadedApp.Init;
begin
  // 1. Call inherited Init. TSampleApp sets up the window AND initializes
  // the TGfx backend (D3D11) here. Without this, sglSetup would crash.
  inherited;

  // 2. Setup Neslib.Sokol.GL (sgl). This must happen AFTER TGfx is ready.
  var GLDesc := TGLDesc.Create;
  GLDesc.UseDelphiMemoryManager := True;
  GLDesc.Logger := GLDesc.DefaultLogger;
  sglSetup(GLDesc);

  // 3. Default pass action to clear the screen to a dark gray background.
  FPassAction.Init;
  FPassAction.Colors[0].Init(TLoadAction.Clear, 0.05, 0.05, 0.05, 1.0);

  // 4. Initialize our custom High-Resolution Timer
  FTimer.Init;
  FFreq := TStopwatch.Frequency;
  if FFreq <= 0 then FFreq := 10000000;

  FNowTicks := FTimer.GetTicks;
  FLastFrameTicks := FNowTicks;
  FNextFrame := FNowTicks;
  FLastFpsTime := FNowTicks;
  FFrameCount := 0;
end;

procedure TSokolThreadedApp.Frame;
begin
  // Check if the VCL thread requested termination
  if TThread.CheckTerminated then
  begin
    Quit;
    Exit;
  end;

  // --- TIMING & PACING ---
  FNowTicks := FTimer.GetTicks;

  // Prevent division by zero if loop executes faster than timer resolution
  if FNowTicks = FLastFrameTicks then
  begin
    FTimer.HybridWaitUntil(FNowTicks + 1, SPIN_THRESHOLD_NS);
    Exit;
  end;

  // Calculate Delta Time for frame-independent physics
  FDeltaSec := (FNowTicks - FLastFrameTicks) / FFreq;
  FLastFrameTicks := FNowTicks;

  // Clamp DeltaSec to prevent physics tunneling on lag spikes (e.g. debugger pause)
  if (FDeltaSec <= 0) or (FDeltaSec > 0.25) then
    FDeltaSec := 1 / 60;

  // Run game logic if not paused
  if not FOwner.FPaused then
    FOwner.UpdateLogic(FDeltaSec);

  FTimeSec := FNowTicks / FFreq;

  // Execute rendering commands
  FOwner.RenderEffect(FTimeSec);

  // --- FPS Calculation ---
  Inc(FFrameCount);
  if (FNowTicks - FLastFpsTime) >= FFreq then
  begin
    FOwner.FRealFPS := Round(FFrameCount * FFreq / (FNowTicks - FLastFpsTime));
    FFrameCount := 0;
    FLastFpsTime := FNowTicks;
  end;

  // --- Frame Limiting Logic ---
  if FOwner.FTargetFPS > 0 then
    FFrameTicks := Round(FFreq / FOwner.FTargetFPS)
  else
    FFrameTicks := FFreq div 60;

  FNextFrame := FNextFrame + FFrameTicks;

  // Drift Correction: If we are falling behind by more than 1 second,
  // reset NextFrame to "now" to prevent a "spiral of death" catch-up burst.
  if (FNowTicks - FNextFrame) > FFreq then
    FNextFrame := FNowTicks;

  // Wait until the next target frame tick
  FTimer.HybridWaitUntil(FNextFrame, SPIN_THRESHOLD_NS);
end;

procedure TSokolThreadedApp.Cleanup;
begin
  // Clean up Sokol GL first, then call inherited Cleanup which destroys
  // the window and shuts down TGfx.
  sglShutdown;
  inherited;
end;

{==============================================================================
  TSokolCustomThreadedBase Implementation
==============================================================================}

constructor TSokolCustomThreadedBase.Create(AOwner: TComponent);
begin
  inherited;
  FThreadActive := False;
  FPaused := True;
  FActive := False;
  FTargetFPS := 60;
  FWindowName := 'SokolWindow_' + AnsiString(IntToStr(IntPtr(Self)));

  // Initialize 3D Cube Position & Velocity for the demo
  FCubePos.x := 0; FCubePos.y := 0; FCubePos.z := 0;
  FCubeVel.x := 3; FCubeVel.y := 3; FCubeVel.z := 3;
  FAngle := 0.0;
end;

destructor TSokolCustomThreadedBase.Destroy;
begin
  StopThread;
  inherited;
end;

procedure TSokolCustomThreadedBase.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if not FThreadActive then
        StartThread;
      FPaused := False;
    end
    else
    begin
      // Pausing doesn't destroy the thread or window, just stops logic updates
      FPaused := True;
    end;
  end;
end;

procedure TSokolCustomThreadedBase.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;

procedure TSokolCustomThreadedBase.StartThread;
begin
  if FThreadActive then Exit;
  FThreadActive := True;

  // Do not start the thread in the IDE designer
  if csDesigning in ComponentState then Exit;

  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      // Create the Sokol Application inside the background thread
      FInternalApp := TSokolThreadedApp.Create(Self);
      try
        // Run() blocks this anonymous thread and enters the Neslib Endless Loop.
        // It will return only when Quit() is called internally.
        FInternalApp.Run;
      finally
        FInternalApp.Free;
        FInternalApp := nil;
        FThreadActive := False;
      end;
    end);

  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TSokolCustomThreadedBase.StopThread;
begin
  if not Assigned(FThread) then Exit;

  // Signal the anonymous thread to terminate
  FThread.Terminate;

  // Wait for the background loop to exit cleanly before freeing
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

{------------------------------------------------------------------------------
  VIRTUAL METHODS
  Override these in descendants to create custom 2D/3D scenes.
------------------------------------------------------------------------------}

procedure TSokolCustomThreadedBase.UpdateLogic(const DeltaTime: Double);
begin
  // 1. Move the cube
  FCubePos.x := FCubePos.x + FCubeVel.x * DeltaTime;
  FCubePos.y := FCubePos.y + FCubeVel.y * DeltaTime;
  FCubePos.z := FCubePos.z + FCubeVel.z * DeltaTime;

  // 2. Bounce off invisible walls
  if Abs(FCubePos.x) > 5 Then FCubeVel.x := -FCubeVel.x;
  if Abs(FCubePos.y) > 5 Then FCubeVel.y := -FCubeVel.y;
  if Abs(FCubePos.z) > 5 Then FCubeVel.z := -FCubeVel.z;

  // 3. Rotate the cube
  FAngle := FAngle + (1.5 * DeltaTime);
end;

procedure TSokolCustomThreadedBase.RenderEffect(const ATime: Double);
var
  BasePoints: array[0..7] of TVec3;
  Rotated: array[0..7] of TVec3;
  Projected: array[0..7] of TPointF;
  i: Integer;
  CosA, SinA: Single;
  ZOffset, FOV: Single;
  Cx, Cy: Single;
  FinalZ: Single;
  Pass: TPass;
begin
  if not Assigned(FInternalApp) then Exit;

  // 1. Sokol GL Setup
  // Set up an orthographic projection for our manually projected 2D points
  sglDefaults;
  sglMatrixModeProjection;
  sglOrtho(0, 800, 600, 0, -1, 1);
  sglMatrixModeModelview;

  // 2. 3D Math (Manual projection for the wireframe cube)
  BasePoints[0].x := -1; BasePoints[0].y := -1; BasePoints[0].z := -1;
  BasePoints[1].x :=  1; BasePoints[1].y := -1; BasePoints[1].z := -1;
  BasePoints[2].x :=  1; BasePoints[2].y :=  1; BasePoints[2].z := -1;
  BasePoints[3].x := -1; BasePoints[3].y :=  1; BasePoints[3].z := -1;
  BasePoints[4].x := -1; BasePoints[4].y := -1; BasePoints[4].z :=  1;
  BasePoints[5].x :=  1; BasePoints[5].y := -1; BasePoints[5].z :=  1;
  BasePoints[6].x :=  1; BasePoints[6].y :=  1; BasePoints[6].z :=  1;
  BasePoints[7].x := -1; BasePoints[7].y :=  1; BasePoints[7].z :=  1;

  CosA := Cos(FAngle);
  SinA := Sin(FAngle);
  ZOffset := 10.0; // Push cube away from camera
  FOV := 400.0;    // Field of view scale factor
  Cx := 400.0;     // Screen center X
  Cy := 300.0;     // Screen center Y

  for i := 0 to 7 do
  begin
    // Simple rotation matrix application
    Rotated[i].x := BasePoints[i].x * CosA - BasePoints[i].z * SinA;
    Rotated[i].z := BasePoints[i].x * SinA + BasePoints[i].z * CosA;
    Rotated[i].y := BasePoints[i].y * CosA - Rotated[i].z * SinA;
    Rotated[i].z := BasePoints[i].y * SinA + Rotated[i].z * CosA;

    // Apply cube position offset
    Rotated[i].x := Rotated[i].x + FCubePos.x;
    Rotated[i].y := Rotated[i].y + FCubePos.y;
    Rotated[i].z := Rotated[i].z + FCubePos.z;

    // Perspective projection
    FinalZ := Rotated[i].z + ZOffset;
    if FinalZ <= 0 then FinalZ := 0.1; // Prevent division by zero

    Projected[i].X := Cx + (Rotated[i].x * (FOV / FinalZ));
    Projected[i].Y := Cy + (Rotated[i].y * (FOV / FinalZ));
  end;

  // 3. Draw cube edges in bright red using Sokol GL
  if FActive then
  begin
    sglBeginLines;
    sglC3f(1.0, 0.2, 0.2);

    // Back face
    sglV2f(Projected[0].X, Projected[0].Y); sglV2f(Projected[1].X, Projected[1].Y);
    sglV2f(Projected[1].X, Projected[1].Y); sglV2f(Projected[2].X, Projected[2].Y);
    sglV2f(Projected[2].X, Projected[2].Y); sglV2f(Projected[3].X, Projected[3].Y);
    sglV2f(Projected[3].X, Projected[3].Y); sglV2f(Projected[0].X, Projected[0].Y);

    // Front face
    sglV2f(Projected[4].X, Projected[4].Y); sglV2f(Projected[5].X, Projected[5].Y);
    sglV2f(Projected[5].X, Projected[5].Y); sglV2f(Projected[6].X, Projected[6].Y);
    sglV2f(Projected[6].X, Projected[6].Y); sglV2f(Projected[7].X, Projected[7].Y);
    sglV2f(Projected[7].X, Projected[7].Y); sglV2f(Projected[4].X, Projected[4].Y);

    // Connecting edges
    sglV2f(Projected[0].X, Projected[0].Y); sglV2f(Projected[4].X, Projected[4].Y);
    sglV2f(Projected[1].X, Projected[1].Y); sglV2f(Projected[5].X, Projected[5].Y);
    sglV2f(Projected[2].X, Projected[2].Y); sglV2f(Projected[6].X, Projected[6].Y);
    sglV2f(Projected[3].X, Projected[3].Y); sglV2f(Projected[7].X, Projected[7].Y);

    sglEnd;
  end;

  // 4. Render Pass (Standard Neslib approach)
  // Create a pass, assign the clear action, and bind the window's swapchain.
  Pass := TPass.Create;
  Pass.Action^ := FInternalApp.FPassAction;
  Pass.Swapchain.FromAppSwapchain;

  // Execute the pass and draw the Sokol GL commands
  TGfx.BeginPass(Pass);
  sglDraw;
  TGfx.EndPass;
  TGfx.Commit;
end;

end.
