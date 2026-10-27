// Win32 calls for AlpsTray.ps1 that Windows PowerShell 5.1 can't make on its own.
// Loaded at run time with Add-Type -Path; there is no build step.
using System;
using System.Runtime.InteropServices;

public static class AlpsTrayNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
