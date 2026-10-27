// Tells whether another process's UI threads still handle messages, without blocking.
// Used by AlpsTray.ps1 to catch a hung Apoint.
//
// Apoint's windows are all hidden, so Process.Responding (main window only) can't see
// a hang. IsHungAppWindow can't either: a thread frozen while waiting in GetMessage
// still counts as "waiting for input", even with messages queued (seen in testing).
// So: send each UI thread a WM_NULL with SendMessageCallback, which returns at once;
// Windows calls OnReply on our thread once the target has handled it. A ping still
// unanswered after N seconds means the thread has stopped handling messages.
// The caller's thread must pump messages (a WinForms message loop does).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class HangProbe {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  delegate void SendAsyncProc(IntPtr h, uint msg, UIntPtr data, IntPtr result);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")]
  static extern bool SendMessageCallback(IntPtr h, uint msg, IntPtr w, IntPtr l, SendAsyncProc cb, UIntPtr data);
  const uint WM_NULL = 0;

  // Kept in a static field so the delegate outlives every pending callback.
  static readonly SendAsyncProc onReply = OnReply;
  static readonly Dictionary<ulong, DateTime> pending = new Dictionary<ulong, DateTime>();
  static ulong nextId;
  static int lastPid;

  static void OnReply(IntPtr h, uint msg, UIntPtr data, IntPtr result) { pending.Remove(data.ToUInt64()); }

  // Seconds the oldest unanswered ping to the process has waited, or 0 if all were
  // answered (then it sends a new ping to each UI thread). Call it every few seconds.
  public static double UnansweredSeconds(int pid) {
    if (pid != lastPid) { pending.Clear(); lastPid = pid; }
    if (pending.Count > 0) {
      DateTime oldest = DateTime.MaxValue;
      foreach (DateTime t in pending.Values) if (t < oldest) oldest = t;
      return (DateTime.Now - oldest).TotalSeconds;
    }
    var oneWindowPerThread = new Dictionary<uint, IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p;
      uint tid = GetWindowThreadProcessId(h, out p);
      if (p == (uint)pid && !oneWindowPerThread.ContainsKey(tid)) oneWindowPerThread[tid] = h;
      return true;
    }, IntPtr.Zero);
    foreach (IntPtr h in oneWindowPerThread.Values) {
      ulong id = ++nextId;
      pending[id] = DateTime.Now;
      if (!SendMessageCallback(h, WM_NULL, IntPtr.Zero, IntPtr.Zero, onReply, new UIntPtr(id))) pending.Remove(id);
    }
    return 0;
  }
}
