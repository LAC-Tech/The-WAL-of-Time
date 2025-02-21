use rand::random;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

trait OS<FD> {
    fn create(&mut self) -> impl Future<Output = FD> + '_;
    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a;
    fn append(
        &mut self,
        fd: FD,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_;
    fn delete(&mut self, fd: FD) -> impl Future<Output = bool> + '_;
}

struct VecFS {
    files: Vec<Option<Vec<u8>>>,
}

struct CreateFuture<'a> {
    fs: &'a mut VecFS,
}

struct ReadFuture<'a> {
    fs: &'a mut VecFS,
    buf: &'a mut Vec<u8>,
    offset: usize,
}

struct AppendFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
    data: Option<Box<[u8]>>, // Updated to Box<[u8]>
}

struct DeleteFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
}

impl<'a> Future for CreateFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        self.fs.files.push(Some(Vec::new()));
        cx.waker().wake_by_ref();
        Poll::Ready(self.fs.files.len() - 1)
    }
}

impl<'a> Future for ReadFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        let file_data = self
            .fs
            .files
            .get(self.offset)
            .and_then(|opt| opt.as_ref())
            .cloned()
            .unwrap_or_default();
        self.buf.clear();
        self.buf.extend_from_slice(&file_data);
        cx.waker().wake_by_ref();
        Poll::Ready(self.buf.len())
    }
}

impl<'a> Future for AppendFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        let fd = self.fd;
        if let Some(data) = self.data.take() {
            if fd < self.fs.files.len() {
                if let Some(file) =
                    self.fs.files.get_mut(fd).and_then(|opt| opt.as_mut())
                {
                    file.extend_from_slice(&data);
                    cx.waker().wake_by_ref();
                    return Poll::Ready(data.len());
                }
            }
        }
        cx.waker().wake_by_ref();
        Poll::Ready(0) // Return 0 if append failed (e.g., invalid FD)
    }
}

impl<'a> Future for DeleteFuture<'a> {
    type Output = bool;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        let fd = self.fd;
        let success = if fd < self.fs.files.len() && self.fs.files[fd].is_some()
        {
            self.fs.files[fd] = None;
            true
        } else {
            false
        };
        cx.waker().wake_by_ref();
        Poll::Ready(success)
    }
}

impl OS<usize> for VecFS {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        CreateFuture { fs: self }
    }

    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a {
        ReadFuture { fs: self, buf, offset }
    }

    fn append(
        &mut self,
        fd: usize,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_ {
        AppendFuture { fs: self, fd, data: Some(data) }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        DeleteFuture { fs: self, fd }
    }
}

struct Task {
    priority: u32,
    future: Pin<Box<dyn Future<Output = ()> + 'static>>,
}

impl PartialEq for Task {
    fn eq(&self, other: &Self) -> bool { self.priority == other.priority }
}

impl Eq for Task {}

impl PartialOrd for Task {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Task {
    fn cmp(&self, other: &Self) -> Ordering {
        self.priority.cmp(&other.priority)
    }
}

struct MiniRuntime {
    tasks: BinaryHeap<Task>,
}

impl MiniRuntime {
    fn new() -> Self { MiniRuntime { tasks: BinaryHeap::new() } }

    fn create_waker(&self) -> Waker {
        fn clone(data: *const ()) -> RawWaker { RawWaker::new(data, &VTABLE) }
        fn wake(_data: *const ()) {}
        fn wake_by_ref(_data: *const ()) {}
        fn drop(_data: *const ()) {}

        static VTABLE: RawWakerVTable =
            RawWakerVTable::new(clone, wake, wake_by_ref, drop);

        unsafe {
            Waker::from_raw(RawWaker::new(
                std::ptr::null::<()>() as *const _,
                &VTABLE,
            ))
        }
    }

    fn spawn(&mut self, future: impl Future<Output = ()> + 'static) {
        let priority = random::<u32>();
        self.tasks.push(Task { priority, future: Box::pin(future) });
    }

    fn run(&mut self) {
        let mut pending = BinaryHeap::new();
        while !self.tasks.is_empty() {
            while let Some(mut task) = self.tasks.pop() {
                let waker = self.create_waker();
                let mut context = Context::from_waker(&waker);
                match task.future.as_mut().poll(&mut context) {
                    Poll::Pending => pending.push(task),
                    Poll::Ready(()) => {}
                }
            }
            std::mem::swap(&mut self.tasks, &mut pending);
        }
    }
}

async fn run_fs(mut fs: VecFS) {
    let fd = fs.create().await;
    println!("Created file with FD: {}", fd);

    let data = vec![42, 43, 44].into_boxed_slice(); // Example with multiple bytes
    let bytes_written = fs.append(fd, data).await;
    println!("Appended {} bytes", bytes_written);

    let mut buf = Vec::new();
    let bytes_read = fs.read(&mut buf, fd).await;
    println!("Read {} bytes: {:?}", bytes_read, buf);

    let success = fs.delete(fd).await;
    println!("Deleted FD {}: {}", fd, success);
}

fn main() {
    let mut runtime = MiniRuntime::new();
    let fs = VecFS { files: Vec::new() };
    runtime.spawn(run_fs(fs));
    runtime.run();
}
