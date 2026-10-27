// Win32 calls for AlpsTray.ps1 that Windows PowerShell 5.1 can't make on its own.
// Loaded at run time with Add-Type -Path; there is no build step.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class AlpsTrayNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern int SetCurrentProcessExplicitAppUserModelID(string id);

  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")]
  static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);
  const uint WM_NULL = 0, SMTO_ABORTIFHUNG = 0x2;

  // True if a UI thread of the process doesn't answer a WM_NULL within timeoutMs.
  // Apoint's windows are all hidden, so Process.Responding (main window only) can't
  // see a hang. IsHungAppWindow can't either: a thread that gets no messages counts
  // as "waiting for input", so a frozen Apoint looked idle (seen in testing). Pinging
  // makes the check real. Costs up to timeoutMs per thread, and only when it is hung.
  public static bool IsHung(int pid, uint timeoutMs) {
    var oneWindowPerThread = new Dictionary<uint, IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p;
      uint tid = GetWindowThreadProcessId(h, out p);
      if (p == (uint)pid && !oneWindowPerThread.ContainsKey(tid)) oneWindowPerThread[tid] = h;
      return true;
    }, IntPtr.Zero);
    foreach (IntPtr h in oneWindowPerThread.Values) {
      IntPtr result;
      if (SendMessageTimeout(h, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, timeoutMs, out result) == IntPtr.Zero) return true;
    }
    return false;
  }
}
