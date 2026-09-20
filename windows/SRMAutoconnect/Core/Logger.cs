using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;

namespace SRMAutoconnect.Core;

public sealed class LogEntry : INotifyPropertyChanged
{
    public Guid Id { get; } = Guid.NewGuid();
    public DateTime Date { get; }
    public string Message { get; }
    public int RepeatCount { get; private set; } = 1;

    public string Text
    {
        get
        {
            var stamp = Date.ToString("HH:mm:ss");
            return RepeatCount > 1 ? $"[{stamp}] {Message} (x{RepeatCount})" : $"[{stamp}] {Message}";
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public LogEntry(DateTime date, string message)
    {
        Date = date;
        Message = message;
    }

    public void IncrementRepeat()
    {
        RepeatCount++;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Text)));
    }
}

public sealed class Logger : IDisposable
{
    public static Logger Shared { get; } = new();

    private const int MaxEntries = 300;
    private const long MaxFileBytes = 1_000_000;

    private readonly BlockingCollection<string> fileQueue = new();
    private readonly Task fileWriterTask;
    private bool disposed;

    public ObservableCollection<LogEntry> Logs { get; } = new();
    public bool DebugEnabled { get; set; }
    public string LogFilePath { get; }

    private Logger()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var logDirectory = Path.Combine(localAppData, "SRMAutoconnect");
        Directory.CreateDirectory(logDirectory);

        LogFilePath = Path.Combine(logDirectory, "SRMAutoconnect.log");
        fileWriterTask = Task.Factory.StartNew(
            ProcessFileQueue,
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    public void Log(string message)
    {
        Emit(message, toUi: true);
    }

    public void Debug(string message)
    {
        Emit(message, toUi: DebugEnabled);
    }

    public void ClearUiLogs()
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher?.CheckAccess() == true)
        {
            Logs.Clear();
        }
        else
        {
            dispatcher?.BeginInvoke(() => Logs.Clear());
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        fileQueue.CompleteAdding();
        try
        {
            fileWriterTask.Wait(TimeSpan.FromSeconds(1));
        }
        catch
        {
            // Logging must never block app shutdown.
        }

        fileQueue.Dispose();
    }

    private void Emit(string message, bool toUi)
    {
        var now = DateTime.Now;
        if (!fileQueue.IsAddingCompleted)
        {
            fileQueue.Add($"[{now:yyyy-MM-dd HH:mm:ss.fff}] {message}");
        }

        Console.WriteLine(message);

        if (!toUi)
        {
            return;
        }

        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher?.CheckAccess() == true)
        {
            AddUiEntry(now, message);
        }
        else
        {
            dispatcher?.BeginInvoke(() => AddUiEntry(now, message));
        }
    }

    private void AddUiEntry(DateTime now, string message)
    {
        if (Logs.Count > 0 && Logs[0].Message == message)
        {
            Logs[0].IncrementRepeat();
            return;
        }

        Logs.Insert(0, new LogEntry(now, message));
        while (Logs.Count > MaxEntries)
        {
            Logs.RemoveAt(Logs.Count - 1);
        }
    }

    private void ProcessFileQueue()
    {
        foreach (var line in fileQueue.GetConsumingEnumerable())
        {
            WriteLine(line);
        }
    }

    private void WriteLine(string line)
    {
        try
        {
            RotateIfNeeded();
            File.AppendAllText(LogFilePath, line + Environment.NewLine);
        }
        catch
        {
            // Avoid recursive logging when the logger itself cannot write.
        }
    }

    private void RotateIfNeeded()
    {
        if (!File.Exists(LogFilePath))
        {
            return;
        }

        var size = new FileInfo(LogFilePath).Length;
        if (size <= MaxFileBytes)
        {
            return;
        }

        var backupPath = LogFilePath + ".1";
        if (File.Exists(backupPath))
        {
            File.Delete(backupPath);
        }

        File.Move(LogFilePath, backupPath);
    }
}
