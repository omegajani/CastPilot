"""
memlib.py — liest den Arbeitsspeicher der DiGiCo-Software (SD7Q.exe), nur lesend.
Läuft unter Wine im selben Prefix wie SD7Q (Windows-Python + ctypes).

Geöffnet wird ausschließlich mit PROCESS_VM_READ | PROCESS_QUERY_INFORMATION.
Es gibt hier keinen Schreibzugriff (kein WriteProcessMemory, kein PROCESS_VM_WRITE).
"""
import ctypes
import ctypes.wintypes as wt

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_NOACCESS, PAGE_GUARD = 0x01, 0x100
READABLE = {0x02, 0x04, 0x08, 0x20, 0x40, 0x80}   # RO, RW, WC, ER, ERW, EWC
WRITABLE = {0x04, 0x08, 0x40, 0x80}               # hier liegen die Laufzeitdaten

k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wt.DWORD),
                ("cntThreads", wt.DWORD), ("th32ParentProcessID", wt.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wt.DWORD),
                ("szExeFile", ctypes.c_wchar * 260)]


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", wt.DWORD), ("PartitionId", wt.WORD),
                ("RegionSize", ctypes.c_size_t), ("State", wt.DWORD),
                ("Protect", wt.DWORD), ("Type", wt.DWORD)]


k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
k32.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
k32.Process32FirstW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
k32.Process32NextW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
k32.OpenProcess.restype = wt.HANDLE
k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.POINTER(MEMORY_BASIC_INFORMATION), ctypes.c_size_t]
k32.ReadProcessMemory.restype = wt.BOOL
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.CloseHandle.argtypes = [wt.HANDLE]


def find_pid(exe="SD7Q.exe"):
    snap = k32.CreateToolhelp32Snapshot(2, 0)   # TH32CS_SNAPPROCESS
    entry = PROCESSENTRY32W()
    entry.dwSize = ctypes.sizeof(entry)
    ok = k32.Process32FirstW(snap, ctypes.byref(entry))
    try:
        while ok:
            if entry.szExeFile.lower() == exe.lower():
                return entry.th32ProcessID
            ok = k32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        k32.CloseHandle(snap)
    return None


class Process:
    """Nur-Lese-Zugriff auf einen Prozess."""

    def __init__(self, pid):
        self.pid = pid
        self.handle = k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
        if not self.handle:
            raise OSError(f"OpenProcess({pid}) fehlgeschlagen, Fehler {ctypes.get_last_error()}")

    def close(self):
        if self.handle:
            k32.CloseHandle(self.handle)
            self.handle = None

    def regions(self, writable_only=True, limit=1 << 47):
        """(Adresse, Größe) aller lesbaren, belegten Speicherbereiche."""
        mbi = MEMORY_BASIC_INFORMATION()
        addr = 0
        while addr < limit:
            if not k32.VirtualQueryEx(self.handle, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
                break
            base = mbi.BaseAddress or 0
            size = mbi.RegionSize
            if size == 0:
                break
            prot = mbi.Protect & 0xFF
            if (mbi.State == MEM_COMMIT and not mbi.Protect & PAGE_GUARD
                    and prot in (WRITABLE if writable_only else READABLE)):
                yield base, size
            addr = base + size

    def read(self, addr, size):
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_size_t(0)
        if not k32.ReadProcessMemory(self.handle, ctypes.c_void_p(addr), buf, size, ctypes.byref(got)):
            return None
        return buf.raw[:got.value]
