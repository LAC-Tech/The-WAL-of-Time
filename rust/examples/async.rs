use rand::random;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

use rust::FileIO;

// An append only file system, support Create, Append, Update, Delete
#[derive(Default)]
struct VecFS {
    files: Vec<Option<Vec<u8>>>,
}

mod future {
    use super::VecFS;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    pub struct Create<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut VecFS,
    }

    pub struct Read<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut VecFS,
        pub buf: &'a mut Vec<u8>,
        pub offset: usize,
    }

    pub struct Append<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut VecFS,
        pub fd: usize,
        pub data: Option<Box<[u8]>>,
    }

    pub struct Delete<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut VecFS,
        pub fd: usize,
    }

    fn waiting(delay_steps: &mut u32, cx: &mut Context<'_>) -> bool {
        if *delay_steps > 0 {
            *delay_steps -= 1;
            cx.waker().wake_by_ref();
            true
        } else {
            false
        }
    }

    impl<'a> Future for Create<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            self.fs.files.push(Some(Vec::new()));
            Poll::Ready(self.fs.files.len() - 1)
        }
    }

    impl<'a> Future for Read<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let file_data = self
                .fs
                .files
                .get(self.offset)
                .and_then(|opt| opt.as_ref())
                .cloned()
                .unwrap_or_default();
            self.buf.clear();
            self.buf.extend_from_slice(&file_data);
            Poll::Ready(self.buf.len())
        }
    }

    impl<'a> Future for Append<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let fd = self.fd;
            let data = match self.data.take() {
                Some(data) => data,
                None => return Poll::Ready(0),
            };

            if fd >= self.fs.files.len() {
                return Poll::Ready(0);
            }

            let file =
                match self.fs.files.get_mut(fd).and_then(|opt| opt.as_mut()) {
                    Some(file) => file,
                    None => return Poll::Ready(0),
                };

            file.extend_from_slice(&data);
            Poll::Ready(data.len())
        }
    }

    impl<'a> Future for Delete<'a> {
        type Output = bool;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let fd = self.fd;
            let success =
                if fd < self.fs.files.len() && self.fs.files[fd].is_some() {
                    self.fs.files[fd] = None;
                    true
                } else {
                    false
                };
            Poll::Ready(success)
        }
    }
}

impl FileIO<usize> for VecFS {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        future::Create { delay_steps: random::<u32>() % 5, fs: self }
    }

    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a {
        future::Read { delay_steps: random::<u32>() % 5, fs: self, buf, offset }
    }

    fn append(
        &mut self,
        fd: usize,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_ {
        future::Append {
            delay_steps: random::<u32>() % 5,
            fs: self,
            fd,
            data: Some(data),
        }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        future::Delete { delay_steps: random::<u32>() % 5, fs: self, fd }
    }
}

// Random priority to increase "chaos" in simulation
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

// Single threaded, deterministic async runtime
struct Runtime {
    tasks: BinaryHeap<Task>,
    waker: Option<Waker>,
}

impl Runtime {
    fn new() -> Self { Runtime { tasks: BinaryHeap::new(), waker: None } }

    fn create_waker(&mut self) -> Waker {
        fn clone(data: *const ()) -> RawWaker { RawWaker::new(data, &VTABLE) }
        fn wake(_data: *const ()) {} // No-op, queue handles re-polling
        fn wake_by_ref(_data: *const ()) {}
        fn drop(_data: *const ()) {}

        static VTABLE: RawWakerVTable =
            RawWakerVTable::new(clone, wake, wake_by_ref, drop);

        if self.waker.is_none() {
            self.waker = Some(unsafe {
                Waker::from_raw(RawWaker::new(
                    std::ptr::null::<()>() as *const _,
                    &VTABLE,
                ))
            });
        }
        self.waker.clone().unwrap()
    }

    fn spawn(&mut self, future: impl Future<Output = ()> + 'static) {
        let priority = random::<u32>();
        self.tasks.push(Task { priority, future: Box::pin(future) });
    }

    fn run(&mut self) {
        while !self.tasks.is_empty() {
            // Poll one task per iteration to avoid overlapping borrows
            if let Some(mut task) = self.tasks.pop() {
                let waker = self.create_waker();
                let mut context = Context::from_waker(&waker);
                match task.future.as_mut().poll(&mut context) {
                    Poll::Pending => self.tasks.push(task),
                    Poll::Ready(()) => {}
                }
            }
        }
    }
}

async fn run_fs(mut fs: VecFS) {
    let fd = fs.create().await;
    println!("Created file with FD: {}", fd);

    let data = vec![42, 43, 44].into_boxed_slice();
    let bytes_written = fs.append(fd, data).await;
    println!("Appended {} bytes", bytes_written);

    let mut buf = Vec::new();
    let bytes_read = fs.read(&mut buf, fd).await;
    println!("Read {} bytes: {:?}", bytes_read, buf);

    let success = fs.delete(fd).await;
    println!("Deleted FD {}: {}", fd, success);
}

fn main() {
    let mut runtime = Runtime::new();
    runtime.spawn(run_fs(VecFS::default()));
    runtime.run();
}
