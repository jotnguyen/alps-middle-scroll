<#
.SYNOPSIS
  Opens a small test window and logs every middle-button, wheel and click event
  as Windows sees it, at two levels.
.DESCRIPTION
  [raw]  = Raw Input (WM_INPUT): what the input stack delivers, and which device
           sent it. "(injected/no device)" means there is no device handle: either
           a precision-touchpad gesture that Windows synthesized, or software input.
  [hook] = low-level mouse hook (WH_MOUSE_LL): the messages applications receive.
           "INJECTED" means a program sent it with SendInput.
  Tap, press and hold the middle button, move a finger, then close the window.
  Changes nothing on the system.
.PARAMETER Out
  Where to save the log. Default: %TEMP%\middle-button-test.log
.EXAMPLE
  powershell -STA -ExecutionPolicy Bypass -File .\scripts\Watch-MiddleButton.ps1
#>
param([string]$Out = (Join-Path $env:TEMP 'middle-button-test.log'))
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Text;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class MBTest : Form {
  [StructLayout(LayoutKind.Sequential)] struct RID { public ushort page, usage; public uint flags; public IntPtr target; }
  [StructLayout(LayoutKind.Sequential)] struct RIHDR { public uint type, size; public IntPtr dev, wparam; }
  [StructLayout(LayoutKind.Sequential)] struct RIMOUSE { public ushort flags; public ushort pad; public ushort btnFlags, btnData; public uint raw; public int x, y; public uint extra; }
  [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RID[] r, uint n, uint sz);
  [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdr);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr d, uint cmd, StringBuilder s, ref uint size);
  delegate IntPtr LLProc(int n, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LLProc p, IntPtr h, uint t);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
  public List<string> Log = new List<string>();
  ListBox box = new ListBox(); LLProc proc; IntPtr hh;
  Dictionary<IntPtr,string> names = new Dictionary<IntPtr,string>();
  int heldMoves = 0; bool mHeld = false;
  public MBTest() {
    Text = "Middle-button test - close this window when done"; Width = 900; Height = 520; TopMost = true;
    var lbl = new Label { Dock = DockStyle.Top, Height = 70, Font = new Font("Segoe UI", 11),
      Text = "1) Press + release the middle button, then move your finger on the touchpad.\n2) Press and HOLD the middle button while moving your finger on the touchpad.\n3) Try the same with the pointing stick (nub) if you have one.  Then close this window." };
    box.Dock = DockStyle.Fill; box.Font = new Font("Consolas", 10);
    Controls.Add(box); Controls.Add(lbl);
    proc = Hook;
  }
  void Add(string s) { s = DateTime.Now.ToString("HH:mm:ss.fff ") + s; Log.Add(s); box.Items.Add(s); box.TopIndex = box.Items.Count - 1; }
  protected override void OnHandleCreated(EventArgs e) {
    base.OnHandleCreated(e);
    var r = new RID[] { new RID { page = 1, usage = 2, flags = 0x100, target = Handle } };
    RegisterRawInputDevices(r, 1, (uint)Marshal.SizeOf(typeof(RID)));
    hh = SetWindowsHookEx(14, proc, GetModuleHandle(null), 0);
    Add("capture started");
  }
  protected override void OnFormClosed(FormClosedEventArgs e) { UnhookWindowsHookEx(hh); base.OnFormClosed(e); }
  string DevName(IntPtr d) {
    if (d == IntPtr.Zero) return "(injected/no device)";
    string n; if (names.TryGetValue(d, out n)) return n;
    uint sz = 512; var sb = new StringBuilder(512); GetRawInputDeviceInfo(d, 0x20000007, sb, ref sz);
    // \\?\HID#VID_x&PID_y&COL01#<instance>#{guid}: keep the hardware ID only, and blank a
    // Bluetooth address, so the log is safe to share.
    n = sb.ToString(); int a = n.IndexOf('#'); int b = a < 0 ? -1 : n.IndexOf('#', a + 1); if (b > 0) n = n.Substring(0, b);
    n = System.Text.RegularExpressions.Regex.Replace(n, "_[0-9A-Fa-f]{12}(?=&|$)", "_<addr>");
    names[d] = n; return n;
  }
  IntPtr Hook(int n, IntPtr w, IntPtr l) {
    if (n >= 0) {
      int msg = (int)w; uint flags = (uint)Marshal.ReadInt32(l, 12); string inj = (flags & 1) != 0 ? "INJECTED" : "hw";
      uint data = (uint)Marshal.ReadInt32(l, 8);
      if (msg == 0x207) Add("[hook] MIDDLE DOWN " + inj);
      else if (msg == 0x208) Add("[hook] MIDDLE UP " + inj);
      else if (msg == 0x20A) Add("[hook] WHEEL " + (short)(data >> 16) + " " + inj);
      else if (msg == 0x20E) Add("[hook] HWHEEL " + (short)(data >> 16) + " " + inj);
    }
    return CallNextHookEx(hh, n, w, l);
  }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0xFF) {
      uint size = 0, hs = (uint)Marshal.SizeOf(typeof(RIHDR));
      GetRawInputData(m.LParam, 0x10000003, IntPtr.Zero, ref size, hs);
      IntPtr buf = Marshal.AllocHGlobal((int)size);
      if (GetRawInputData(m.LParam, 0x10000003, buf, ref size, hs) == size) {
        var h = (RIHDR)Marshal.PtrToStructure(buf, typeof(RIHDR));
        var mo = (RIMOUSE)Marshal.PtrToStructure(IntPtr.Add(buf, (int)hs), typeof(RIMOUSE));
        string dev = DevName(h.dev);
        if (mo.btnFlags != 0) {
          var parts = new List<string>();
          if ((mo.btnFlags & 0x1) != 0) parts.Add("LEFT_DOWN"); if ((mo.btnFlags & 0x2) != 0) parts.Add("LEFT_UP");
          if ((mo.btnFlags & 0x4) != 0) parts.Add("RIGHT_DOWN"); if ((mo.btnFlags & 0x8) != 0) parts.Add("RIGHT_UP");
          if ((mo.btnFlags & 0x10) != 0) { parts.Add("MIDDLE_DOWN"); mHeld = true; heldMoves = 0; }
          if ((mo.btnFlags & 0x20) != 0) { parts.Add("MIDDLE_UP (moves while held: " + heldMoves + ")"); mHeld = false; }
          if ((mo.btnFlags & 0x400) != 0) parts.Add("WHEEL " + (short)mo.btnData);
          if ((mo.btnFlags & 0x800) != 0) parts.Add("HWHEEL " + (short)mo.btnData);
          if (parts.Count == 0) parts.Add("flags=0x" + mo.btnFlags.ToString("X"));
          Add("[raw] " + string.Join(",", parts) + "  dev=" + dev);
        } else if (mHeld && (mo.x != 0 || mo.y != 0)) { if (heldMoves++ == 0) Add("[raw] movement while middle held  dev=" + dev); }
      }
      Marshal.FreeHGlobal(buf);
    }
    base.WndProc(ref m);
  }
}
"@
$f = New-Object MBTest
[System.Windows.Forms.Application]::Run($f)
$f.Log | Set-Content -Encoding utf8 $Out
Write-Host "Log saved to $Out"
