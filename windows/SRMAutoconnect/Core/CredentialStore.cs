using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SRMAutoconnect.Core;

public sealed class CredentialStoreException : Exception
{
    public string Operation { get; }
    public string Target { get; }
    public int ErrorCode { get; }

    public CredentialStoreException(string operation, string target, int errorCode)
        : base($"{operation} failed for {target}: {new Win32Exception(errorCode).Message}")
    {
        Operation = operation;
        Target = target;
        ErrorCode = errorCode;
    }
}

public sealed class CredentialStore
{
    public const string UsernameTarget = "SRMAutoconnect/username";
    public const string PasswordTarget = "SRMAutoconnect/password";

    public static CredentialStore Shared { get; } = new();

    private const int CredentialTypeGeneric = 1;
    private const int CredentialPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const int MaxCredentialBlobBytes = 5 * 512;

    private CredentialStore()
    {
    }

    public void Save(byte[] data, string target)
    {
        ArgumentNullException.ThrowIfNull(data);
        ValidateTarget(target);

        if (data.Length > MaxCredentialBlobBytes)
        {
            throw new ArgumentException(
                $"Credential data is too large. Windows generic credentials allow {MaxCredentialBlobBytes} bytes.",
                nameof(data));
        }

        var blob = Marshal.AllocCoTaskMem(data.Length);
        try
        {
            Marshal.Copy(data, 0, blob, data.Length);

            var credential = new NativeCredential
            {
                Type = CredentialTypeGeneric,
                TargetName = target,
                CredentialBlobSize = (uint)data.Length,
                CredentialBlob = blob,
                Persist = CredentialPersistLocalMachine,
                UserName = Environment.UserName
            };

            if (!CredWrite(ref credential, 0))
            {
                ThrowLastError("Save", target);
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(blob);
        }
    }

    public byte[]? Read(string target)
    {
        ValidateTarget(target);

        if (!CredRead(target, CredentialTypeGeneric, 0, out var credentialPtr))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null;
            }

            throw new CredentialStoreException("Read", target, error);
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(credentialPtr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return Array.Empty<byte>();
            }

            var data = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, data, 0, data.Length);
            return data;
        }
        finally
        {
            CredFree(credentialPtr);
        }
    }

    public void Delete(string target)
    {
        ValidateTarget(target);

        if (CredDelete(target, CredentialTypeGeneric, 0))
        {
            return;
        }

        var error = Marshal.GetLastWin32Error();
        if (error == ErrorNotFound)
        {
            return;
        }

        throw new CredentialStoreException("Delete", target, error);
    }

    private static void ValidateTarget(string target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            throw new ArgumentException("Credential target cannot be empty.", nameof(target));
        }
    }

    private static void ThrowLastError(string operation, string target)
    {
        throw new CredentialStoreException(operation, target, Marshal.GetLastWin32Error());
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref NativeCredential userCredential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }
}
