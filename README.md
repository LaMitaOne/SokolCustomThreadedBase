# SokolCustomThreadedBase
A high-performance, threaded Delphi component that integrates Neslib.Sokol into VCL applications without blocking the UI thread.

Neslib.SokolCustomThreadedBase v0.1    

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SokolCustomThreadedBase)
    
<img width="802" height="659" alt="Unbenannt" src="https://github.com/user-attachments/assets/9f1527e9-90e4-4ee1-a3cb-5aa3759c9f78" />
    
yes really 3957 fps max i get here at rtx2060s. So think Sokol wins compared to sdl3 or raylib...    
    
This base class provides a robust, drop-in architecture for running Sokol's immediate-mode rendering loop entirely in the background, making it perfect for creating complex visualizations, editors, or interactive 3D tools directly inside Delphi.     
     
Key Features:     
     
     Threaded Architecture: Separates the entire Sokol Lifecycle (Init, Frame, Cleanup) from the VCL UI thread. The main application remains 100% responsive.
     Native Neslib TSampleApp Integration: Instead of fighting Neslib's internal lifecycle management, this component correctly derives from TSampleApp and maps the VCL thread directly into Neslib's expected Run loop.
     Precise QPC Frame Pacing: Utilizes QueryPerformanceCounter (via TStopwatch) to calculate absolute frame deadlines. 
     Hybrid Sleep/SpinWait: Uses a two-phase wait strategy (Sleep(0/1) for the bulk of the frame, busy-spin the last ~2ms) to guarantee frame-exact timing without burning unnecessary CPU cycles.
     V-Sync Independent: Explicitly disables Sokol's internal V-Sync (SwapInterval = 0) and handles frame limiting manually, allowing the loop to hit extreme FPS targets (1000+ FPS) when VCL overhead is removed.
     Immediate-Mode GL (sgl) Support: Safely initializes and tears down Neslib.Sokol.GL (sglSetup/sglShutdown) exactly within the Neslib lifetime, preventing _sg.valid assertion crashes.
     Delta Time Updates: Logic updates use real measured delta times with safety clamping (prevents huge jumps after debugger pauses or stalls).
     Drift Correction: If the loop falls behind by more than 1 second, it resyncs to "now" instead of rushing a burst of frames to catch up.
    
Sample exe and project included     
     
The repository includes a ready-to-run "Flying Cube" demo that shows:    
    
     How to drop TSokolCustomThreadedBase onto a VCL form.
     How to override UpdateLogic (3D physics/math).
     How to override RenderEffect (Sokol GL drawing calls).
     UI controls to Start/Stop the loop and toggle FPS on the fly.
    
Technical Requirements:   
    
     Delphi (VCL)
     Neslib.Sokol (including Neslib.Sokol.Glue and the SampleApp unit)
     Windows (due to Winapi.Windows usage for threading and timer resolution)
     
Latest Changes:   
   
v0.1:    
   
     Initial Release: Successfully merged the VCL TThread architecture with Neslib's TSampleApp lifecycle. 
     Performance: Disabled hardware V-Sync to allow manual HighResTimer frame pacing.
     Demo: Implemented the classic bouncing 3D wireframe cube (ported 1:1 from the SDL3/Raylib samples) rendered via sglDraw. 

Sokol units from neslib: https://github.com/neslib/Neslib.Sokol    
   

smaller window makes a bit more fps lol 7600...   
<img width="594" height="291" alt="Unbenannt" src="https://github.com/user-attachments/assets/1657df5e-20a0-4151-8339-f03a27a48a53" />
