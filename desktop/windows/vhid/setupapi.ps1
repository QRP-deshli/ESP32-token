# SetupAPI calls shared by install.ps1 and uninstall.ps1 (what devcon.exe does, without needing the WDK tools).
$PicoHardwareId = 'Root\PicoVhf'
$PicoHidClassGuid = [Guid]'745a17a0-74d3-11d0-b6fe-00a0c90f57da'

if (-not ('PicoSetupApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class PicoSetupApi {
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfoW(IntPtr set, string name, ref Guid classGuid, string desc, IntPtr hwnd,
                                                uint flags, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref SP_DEVINFO_DATA data, uint prop, byte[] buf, uint size);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(uint fn, IntPtr set, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwnd, string hwid, string inf, uint flags, out bool reboot);

    const uint DICD_GENERATE_ID = 1, SPDRP_HARDWAREID = 1, DIF_REGISTERDEVICE = 0x19, INSTALLFLAG_FORCE = 1;

    // Creates ROOT\<class>\NNNN with the given hardware ID (like "devcon install" does before installing the driver).
    public static void CreateRootDevice(string hwid, string className, Guid classGuid) {
        IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (set == new IntPtr(-1)) throw new Win32Exception();
        try {
            var data = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA)) };
            if (!SetupDiCreateDeviceInfoW(set, className, ref classGuid, null, IntPtr.Zero, DICD_GENERATE_ID, ref data))
                throw new Win32Exception();
            byte[] ids = Encoding.Unicode.GetBytes(hwid + "\0\0");     // REG_MULTI_SZ
            if (!SetupDiSetDeviceRegistryPropertyW(set, ref data, SPDRP_HARDWAREID, ids, (uint)ids.Length))
                throw new Win32Exception();
            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref data))
                throw new Win32Exception();
        } finally { SetupDiDestroyDeviceInfoList(set); }
    }

    // Installs the INF on every present device with this hardware ID; returns true if Windows wants a reboot.
    public static bool InstallDriver(string hwid, string infPath) {
        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hwid, infPath, INSTALLFLAG_FORCE, out reboot))
            throw new Win32Exception();
        return reboot;
    }
}
'@
}

# The installed Root\PicoVhf device(s), if any.
function Get-PicoVhfDevice {
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains $PicoHardwareId }
}
