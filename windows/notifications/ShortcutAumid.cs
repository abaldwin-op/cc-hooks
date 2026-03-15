// Sets the AppUserModelID (AUMID) property on a Windows .lnk shortcut file.
//
// Windows requires a Start Menu shortcut with an AUMID for unpackaged desktop apps
// to show toast notifications. The AUMID links the shortcut to the notification source,
// controlling the attribution text and icon shown at the top of each toast.
//
// Used by install.ps1 during one-time setup. Not compiled into the main exe —
// loaded at runtime via PowerShell's Add-Type.
//
// All GUIDs and interfaces are from the Windows SDK (shell32, propsys).

using System;
using System.Runtime.InteropServices;

public class ShortcutAumid {
    // Shell32 API to open a file's property store for reading/writing metadata
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc, int flags,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ppv);

    // IPropertyStore — standard Windows COM interface for file property access
    // GUID: 886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99 (defined by Microsoft in propsys.h)
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint c);
        void GetAt(uint i, out PROPERTYKEY k);
        void GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
        void SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT { public ushort vt; ushort r1, r2, r3; public IntPtr data; }

    /// <summary>
    /// Sets the System.AppUserModel.ID property on a .lnk shortcut file.
    /// PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid 5
    /// </summary>
    public static void Set(string shortcutPath, string aumid) {
        IPropertyStore store;
        // GPS_READWRITE = 2 (open for writing)
        int hr = SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, 2,
            new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), out store);
        if (hr != 0) throw new COMException("SHGetPropertyStoreFromParsingName failed", hr);

        // VT_LPWSTR = 31 (property value is a Unicode string)
        var key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        var val = new PROPVARIANT { vt = 31, data = Marshal.StringToCoTaskMemUni(aumid) };
        store.SetValue(ref key, ref val);
        store.Commit();
        Marshal.FreeCoTaskMem(val.data);
    }
}
