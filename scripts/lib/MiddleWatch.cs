// Remembers the last middle-button press Windows received and which device sent it.
// Raw Input only, not a hook, so it can't slow the mouse down. Used by AlpsTray.ps1:
// if presses stop arriving, the Alps side is broken; if they arrive, look at the app.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class MiddleWatch : NativeWindow {
  [StructLayout(LayoutKind.Sequential)] struct RID { public ushort page, usage; public uint flags; public IntPtr target; }
  [StructLayout(LayoutKind.Sequential)] struct RIHDR { public uint type, size; public IntPtr dev, wparam; }
  [StructLayout(LayoutKind.Sequential)] struct RIMOUSE { public ushort flags; public ushort pad; public ushort btnFlags, btnData; public uint raw; public int x, y; public uint extra; }
  [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RID[] r, uint n, uint sz);
  [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdr);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr d, uint cmd, StringBuilder s, ref uint size);

  const int WM_INPUT = 0xFF;
  const uint RID_INPUT = 0x10000003, RIDI_DEVICENAME = 0x20000007, RIDEV_INPUTSINK = 0x100;
  const ushort RI_MOUSE_MIDDLE_BUTTON_DOWN = 0x10;

  public DateTime Last = DateTime.MinValue;
  public string LastFrom = "";
  public int Count;
  // Every mouse event seen. If this grows while Count doesn't, Raw Input works and the
  // middle presses really aren't reaching Windows.
  public long Events;
  readonly Dictionary<IntPtr, string> kinds = new Dictionary<IntPtr, string>();

  public MiddleWatch() {
    CreateHandle(new CreateParams());
    // Generic desktop page, mouse usage; INPUTSINK delivers input while we're in the background.
    var r = new RID[] { new RID { page = 1, usage = 2, flags = RIDEV_INPUTSINK, target = Handle } };
    RegisterRawInputDevices(r, 1, (uint)Marshal.SizeOf(typeof(RID)));
  }

  // A friendly name only; the device path holds the machine's instance ID.
  string Kind(IntPtr d) {
    if (d == IntPtr.Zero) return "no device (the Alps helper or a gesture)";
    string k;
    if (kinds.TryGetValue(d, out k)) return k;
    uint sz = 512;
    var sb = new StringBuilder(512);
    GetRawInputDeviceInfo(d, RIDI_DEVICENAME, sb, ref sz);
    string n = sb.ToString().ToUpperInvariant();
    if (n.Contains("VID_044E")) k = "the stick (Alps)";
    else if (n.Contains("DELL0")) k = "the touchpad";
    else k = "another mouse";
    kinds[d] = k;
    return k;
  }

  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_INPUT) {
      uint size = 0, hs = (uint)Marshal.SizeOf(typeof(RIHDR));
      GetRawInputData(m.LParam, RID_INPUT, IntPtr.Zero, ref size, hs);
      IntPtr buf = Marshal.AllocHGlobal((int)size);
      try {
        if (GetRawInputData(m.LParam, RID_INPUT, buf, ref size, hs) == size) {
          var h = (RIHDR)Marshal.PtrToStructure(buf, typeof(RIHDR));
          var mo = (RIMOUSE)Marshal.PtrToStructure(IntPtr.Add(buf, (int)hs), typeof(RIMOUSE));
          Events++;
          if ((mo.btnFlags & RI_MOUSE_MIDDLE_BUTTON_DOWN) != 0) { Last = DateTime.Now; LastFrom = Kind(h.dev); Count++; }
        }
      } finally { Marshal.FreeHGlobal(buf); }
    }
    base.WndProc(ref m);
  }
}
