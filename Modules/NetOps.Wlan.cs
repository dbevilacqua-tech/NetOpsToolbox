using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace NetOpsToolbox.Windows
{
    public static class Wlan
    {
        private const uint ClientVersion = 2;
        private const int InterfaceListHeaderSize = 8;
        private const int MaxNameLength = 256;
        private const int MaxSsidLength = 32;
        private const int MaxRadioCount = 64;
        private const uint InvalidData = 13;

        private enum QueryOpcode
        {
            RadioState = 4,
            CurrentConnection = 7,
            Channel = 8
        }

        public enum InterfaceState : uint
        {
            NotReady,
            Connected,
            AdHocNetworkFormed,
            Disconnecting,
            Disconnected,
            Associating,
            Discovering,
            Authenticating
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct InterfaceInfo
        {
            public Guid Id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxNameLength)]
            public string Description;
            public InterfaceState State;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RadioState
        {
            public uint PhyIndex;
            public uint SoftwareState;
            public uint HardwareState;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RadioStateList
        {
            public uint Count;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = MaxRadioCount)]
            public RadioState[] Radios;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Association
        {
            public uint SsidLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = MaxSsidLength)]
            public byte[] Ssid;
            public uint NetworkType;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
            public byte[] Bssid;
            public uint PhyType;
            public uint PhyIndex;
            public uint SignalQuality;
            public uint ReceiveRateKbps;
            public uint TransmitRateKbps;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Security
        {
            public int Enabled;
            public int OneXEnabled;
            public uint Authentication;
            public uint Cipher;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct Connection
        {
            public InterfaceState State;
            public uint Mode;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxNameLength)]
            public string Profile;
            public Association Association;
            public Security Security;
        }

        public sealed class Snapshot
        {
            public InterfaceInfo Info { get; internal set; }
            public RadioState[] Radios { get; internal set; } = Array.Empty<RadioState>();
            public uint RadioError { get; internal set; }
            public Connection? ActiveConnection { get; internal set; }
            public uint ConnectionError { get; internal set; }
            public uint? Channel { get; internal set; }
        }

        public static Snapshot[] ReadInterfaces()
        {
            uint status = WlanOpenHandle(ClientVersion, IntPtr.Zero, out _, out IntPtr handle);
            if (status != 0)
                throw new Win32Exception((int)status);

            try
            {
                status = WlanEnumInterfaces(handle, IntPtr.Zero, out IntPtr list);
                if (status != 0)
                    throw new Win32Exception((int)status);

                try
                {
                    int count = Marshal.ReadInt32(list);
                    int itemSize = Marshal.SizeOf<InterfaceInfo>();
                    var interfaces = new Snapshot[count];

                    for (int index = 0; index < count; index++)
                    {
                        IntPtr item = IntPtr.Add(list, checked(InterfaceListHeaderSize + index * itemSize));
                        interfaces[index] = ReadInterface(handle, Marshal.PtrToStructure<InterfaceInfo>(item));
                    }
                    return interfaces;
                }
                finally { WlanFreeMemory(list); }
            }
            finally { WlanCloseHandle(handle, IntPtr.Zero); }
        }

        private static Snapshot ReadInterface(IntPtr handle, InterfaceInfo info)
        {
            var result = new Snapshot { Info = info };
            RadioStateList? radios = Query<RadioStateList>(handle, info.Id, QueryOpcode.RadioState, out uint radioError);
            result.RadioError = radioError;
            if (radios.HasValue)
            {
                RadioStateList list = radios.Value;
                if (list.Count <= MaxRadioCount)
                {
                    result.Radios = new RadioState[list.Count];
                    Array.Copy(list.Radios, result.Radios, result.Radios.Length);
                }
                else
                {
                    result.RadioError = InvalidData;
                }
            }

            if (info.State == InterfaceState.Connected || info.State == InterfaceState.AdHocNetworkFormed)
            {
                result.ActiveConnection = Query<Connection>(handle, info.Id, QueryOpcode.CurrentConnection, out uint connectionError);
                result.ConnectionError = connectionError;
                if (result.ActiveConnection.HasValue)
                    result.Channel = Query<uint>(handle, info.Id, QueryOpcode.Channel, out _);
            }

            return result;
        }

        private static T? Query<T>(IntPtr handle, Guid id, QueryOpcode opcode, out uint status) where T : struct
        {
            status = WlanQueryInterface(handle, ref id, opcode, IntPtr.Zero, out uint dataSize, out IntPtr data, IntPtr.Zero);
            if (status != 0)
                return null;

            try
            {
                if (data == IntPtr.Zero || dataSize < Marshal.SizeOf<T>())
                {
                    status = InvalidData;
                    return null;
                }
                return Marshal.PtrToStructure<T>(data);
            }
            finally
            {
                if (data != IntPtr.Zero)
                    WlanFreeMemory(data);
            }
        }

        [DllImport("wlanapi.dll", ExactSpelling = true)]
        private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint version, out IntPtr handle);

        [DllImport("wlanapi.dll", ExactSpelling = true)]
        private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);

        [DllImport("wlanapi.dll", ExactSpelling = true)]
        private static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);

        [DllImport("wlanapi.dll", ExactSpelling = true)]
        private static extern uint WlanQueryInterface(IntPtr handle, ref Guid id, QueryOpcode opcode, IntPtr reserved,
            out uint dataSize, out IntPtr data, IntPtr valueType);

        [DllImport("wlanapi.dll", ExactSpelling = true)]
        private static extern void WlanFreeMemory(IntPtr memory);
    }
}
