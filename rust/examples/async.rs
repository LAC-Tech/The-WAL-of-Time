use std::future::Future;
use std::task::{Context, Poll, Waker, RawWaker, RawWakerVTable};
use std::collections::BinaryHeap;
use std::pin::Pin;
use std::cmp::Ordering;
use rand::random;

trait OS<FD> {
    fn create(&mut self) -> impl Future<Output = FD> + '_;
    fn read<'a>(&'a mut self, buf: &'a mut Vec<u8>, offset: usize) -> impl Future<Output = usize> + 'a;
    fn append(&mut self, fd: FD, data: Box<u8>) -> impl Future<Output = usize> + '_;
    fn delete(&mut self, fd: FD) -> impl Future<Output = bool> + '_;
}

struct VecFS {
    files: Vec<Option<Vec<u8>>>,
}

struct CreateFuture<'a> {
    fs: &'a mut VecFS,
    done: bool,
}

struct ReadFuture<'a> {
    fs: &'a mut VecFS,
    buf: &'a mut Vec<u8>,
    offset: usize,
    done: bool,
}

struct AppendFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
    data: Option<Box<u8>>,
    done: bool,
}

struct DeleteFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
    done: bool,
}

impl<'a> Future for CreateFuture<'a> {
    type Output = usize;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.done {
            Poll::Ready(self.fs.files.len() - 1)
        } else {
            self.fs.files.push(Some(Vec::new()));
            self.done = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

impl<'a> Future for ReadFuture<'a> {
    type Output = usize;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.done {
            Poll::Ready(self.buf.len())
        } else {
            let file_data = self.fs.files.get(self.offset).and_then(|opt| opt.as_ref()).cloned().unwrap_or_default();
            self.buf.clear();
            self.buf.extend_from_slice(&file_data);
            self.done = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

impl<'a> Future for AppendFuture<'a> {
    type Output = usize;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.done {
            Poll::Ready(1)
        } else {
            let fd = self.fd;
            let data = self.data.take();
            if fd < self.fs.files.len() {
                if let Some(Some(file)) = self.fs.files.get_mut(fd) {
                    if let Some(d) = data {
                        file.push(*d);
                    }
                }
            }
            self.done = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

impl<'a> Future for DeleteFuture<'a> {
    type Output = bool;

    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        let fd = self.fd;
        let success = if fd < self.fs.files.len() && self.fs.files[fd].is_some() {
            self.fs.files[fd] = None; // Mark as deleted
            true
        } else {
            false
        };
        Poll::Ready(success) // Complete immediately with the result
    }
}

impl OS<usize> for VecFS {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        CreateFuture { fs: self, done: false }
    }

    fn read<'a>(&'a mut self, buf: &'a mut Vec<u8>, offset: usize) -> impl Future<Output = usize> + 'a {
        ReadFuture { fs: self, buf, offset, done: false }
    }

    fn append(&mut self, fd: usize, data: Box<u8>) -> impl Future<Output = usize> + '_ {
        AppendFuture { fs: self, fd, data: Some(data), done: false }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        DeleteFuture { fs: self, fd, done: false }
    }
}

struct Task {
    priority: u32,
    future: Pin<Box<dyn Future<Output = ()> + 'static>>,
}

impl PartialEq for Task {
    fn eq(&self, other: &Self) -> bool {
        self.priority == other.priority
    }
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
    pending: BinaryHeap<Task>,
    waker: Option<Waker>,
}

impl MiniRuntime {
    fn new() -> Self {
        MiniRuntime {
            tasks: BinaryHeap::new(),
            pending: BinaryHeap::new(),
            waker: None,
        }
    }

    fn create_waker(&mut self) -> Waker {
        fn clone(data: *const ()) -> RawWaker {
            RawWaker::new(data, &VTABLE)
        }
        fn wake(data: *const ()) {
            let runtime = unsafe { &mut *(data as *mut MiniRuntime) };
            while let Some(task) = runtime.pending.pop() {
                runtime.tasks.push(task);
            }
        }
        fn wake_by_ref(data: *const ()) {
            let runtime = unsafe { &mut *(data as *mut MiniRuntime) };
            while let Some(task) = runtime.pending.pop() {
                runtime.tasks.push(task);
            }
        }
        fn drop(_data: *const ()) {}

        static VTABLE: RawWakerVTable = RawWakerVTable::new(clone, wake, wake_by_ref, drop);

        if self.waker.is_none() {
            self.waker = Some(unsafe {
                Waker::from_raw(RawWaker::new(self as *mut _ as *const _, &VTABLE))
            });
        }
        self.waker.clone().unwrap()
    }

    fn spawn(&mut self, future: impl Future<Output = ()> + 'static) {
        let priority = random::<u32>();
        self.tasks.push(Task {
            priority,
            future: Box::pin(future),
        });
    }

    fn run(&mut self) {
        while !self.tasks.is_empty() || !self.pending.is_empty() {
            while let Some(mut task) = self.tasks.pop() {
                let waker = self.create_waker();
                let mut context = Context::from_waker(&waker);

                match task.future.as_mut().poll(&mut context) {
                    Poll::Pending => {
                        self.pending.push(task);
                    }
                    Poll::Ready(()) => {}
                }
            }
            if self.tasks.is_empty() && !self.pending.is_empty() {
                while let Some(task) = self.pending.pop() {
                    self.tasks.push(task);
                }
            }
        }
    }
}

async fn run_fs(mut fs: VecFS) {
    let fd = fs.create().await;
    println!("Created file with FD: {}", fd);

    let bytes_written = fs.append(fd, Box::new(42)).await;
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
