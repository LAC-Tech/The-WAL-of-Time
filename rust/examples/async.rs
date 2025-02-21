use rand::random;
use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

use rust::OperatingSystem;

struct VecFS {
    files: Vec<Option<Vec<u8>>>,
}

struct CreateFuture<'a> {
    fs: &'a mut VecFS,
    delay_steps: u32,
}

struct ReadFuture<'a> {
    fs: &'a mut VecFS,
    buf: &'a mut Vec<u8>,
    offset: usize,
    delay_steps: u32,
}

struct AppendFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
    data: Option<Box<[u8]>>,
    delay_steps: u32,
}

struct DeleteFuture<'a> {
    fs: &'a mut VecFS,
    fd: usize,
    delay_steps: u32,
}

impl<'a> Future for CreateFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        if self.delay_steps > 0 {
            self.delay_steps -= 1;
            cx.waker().wake_by_ref();
            Poll::Pending
        } else {
            self.fs.files.push(Some(Vec::new()));
            Poll::Ready(self.fs.files.len() - 1)
        }
    }
}

impl<'a> Future for ReadFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        if self.delay_steps > 0 {
            self.delay_steps -= 1;
            cx.waker().wake_by_ref();
            Poll::Pending
        } else {
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
}

impl<'a> Future for AppendFuture<'a> {
    type Output = usize;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        if self.delay_steps > 0 {
            self.delay_steps -= 1;
            cx.waker().wake_by_ref();
            Poll::Pending
        } else {
            let fd = self.fd;
            if let Some(data) = self.data.take() {
                if fd < self.fs.files.len() {
                    if let Some(file) =
                        self.fs.files.get_mut(fd).and_then(|opt| opt.as_mut())
                    {
                        file.extend_from_slice(&data);
                        return Poll::Ready(data.len());
                    }
                }
            }
            Poll::Ready(0)
        }
    }
}

impl<'a> Future for DeleteFuture<'a> {
    type Output = bool;

    fn poll(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        if self.delay_steps > 0 {
            self.delay_steps -= 1;
            cx.waker().wake_by_ref();
            Poll::Pending
        } else {
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

impl OperatingSystem<usize> for VecFS {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        CreateFuture { fs: self, delay_steps: random::<u32>() % 5 }
    }

    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a {
        ReadFuture { fs: self, buf, offset, delay_steps: random::<u32>() % 5 }
    }

    fn append(
        &mut self,
        fd: usize,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_ {
        AppendFuture {
            fs: self,
            fd,
            data: Some(data),
            delay_steps: random::<u32>() % 5,
        }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        DeleteFuture { fs: self, fd, delay_steps: random::<u32>() % 5 }
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
    waker: Option<Waker>,
}

impl MiniRuntime {
    fn new() -> Self { MiniRuntime { tasks: BinaryHeap::new(), waker: None } }

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
                    Poll::Pending => self.tasks.push(task), /* Requeue immediately */
                    Poll::Ready(()) => {}
                }
            }
        }
    }
}

async fn run_fs(fs: Rc<RefCell<VecFS>>) {
    let fd = fs.borrow_mut().create().await;
    println!("Created file with FD: {}", fd);

    let data = vec![42, 43, 44].into_boxed_slice();
    let bytes_written = fs.borrow_mut().append(fd, data).await;
    println!("Appended {} bytes", bytes_written);

    let mut buf = Vec::new();
    let bytes_read = fs.borrow_mut().read(&mut buf, fd).await;
    println!("Read {} bytes: {:?}", bytes_read, buf);

    let success = fs.borrow_mut().delete(fd).await;
    println!("Deleted FD {}: {}", fd, success);
}

fn main() {
    let mut runtime = MiniRuntime::new();
    let fs = Rc::new(RefCell::new(VecFS { files: Vec::new() }));

    runtime.spawn({
        let fs = fs.clone();
        async move {
            let fd = fs.borrow_mut().create().await;
            println!("First FD={}", fd);
        }
    });
    runtime.spawn({
        let fs = fs.clone();
        async move {
            let fd = fs.borrow_mut().create().await;
            println!("Second FD={}", fd);
        }
    });
    runtime.spawn({
        let fs = fs.clone();
        async move {
            let fd = fs.borrow_mut().create().await;
            println!("Third FD={}", fd);
        }
    });
    runtime.spawn(run_fs(fs));

    runtime.run();
}
