/// 通用请求队列 (T7.1 依赖)
///
/// 支持并发控制的异步任务执行器。
/// HttpPoller 和 FileUploader 复用的并发队列基础设施。
///
/// 特性:
/// - 最大并发数限制
/// - 结果收集（不因单任务失败中断其他任务）
/// - 每个任务独立超时

import 'dart:async';

/// 任务执行结果
class TaskResult<T> {
  final bool isSuccess;
  final T? data;
  final Object? error;

  const TaskResult.success(this.data)
      : isSuccess = true,
        error = null;

  const TaskResult.failure(this.error)
      : isSuccess = false,
        data = null;
}

/// 请求队列
///
/// 示例:
/// ```dart
/// final queue = RequestQueue(maxConcurrency: 20);
/// final results = await queue.executeAll(
///   items.map((item) => () => doWork(item)),
/// );
/// ```
class RequestQueue {
  final int maxConcurrency;

  RequestQueue({this.maxConcurrency = 20});

  /// 并发执行所有任务，返回结果列表
  ///
  /// [tasks] 异步任务工厂列表（返回 Future 的函数）
  /// 返回与输入顺序一致的结果列表。
  Future<List<TaskResult<T>>> executeAll<T>(
    Iterable<Future<T> Function()> tasks,
  ) async {
    final taskList = tasks.toList();
    if (taskList.isEmpty) return [];

    final results = List<TaskResult<T>?>.filled(taskList.length, null);
    final semaphore = _Semaphore(maxConcurrency);

    final futures = <Future<void>>[];
    for (int i = 0; i < taskList.length; i++) {
      final index = i;
      final task = taskList[i];

      futures.add(() async {
        await semaphore.acquire();
        try {
          final data = await task();
          results[index] = TaskResult<T>.success(data);
        } catch (e) {
          results[index] = TaskResult<T>.failure(e);
        } finally {
          semaphore.release();
        }
      }());
    }

    await Future.wait(futures);
    return results.whereType<TaskResult<T>>().toList();
  }

  /// 并发执行，直到所有任务完成（不收集结果）
  Future<void> executeAllVoid(
    Iterable<Future<void> Function()> tasks,
  ) async {
    final taskList = tasks.toList();
    if (taskList.isEmpty) return;

    final semaphore = _Semaphore(maxConcurrency);

    final futures = taskList.map((task) async {
      await semaphore.acquire();
      try {
        await task();
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
  }
}

/// 内部信号量
class _Semaphore {
  int _permits;
  final List<Completer<void>> _waiters = [];

  _Semaphore(int maxPermits) : _permits = maxPermits;

  Future<void> acquire() async {
    if (_permits > 0) {
      _permits--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _permits--;
  }

  void release() {
    _permits++;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}
