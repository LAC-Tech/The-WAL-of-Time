#[no_std]
extern crate alloc;

use alloc::vec::Vec;

pub struct Node<Env, OS>
where
    OS: os::OperatingSystem,
{
    os: OS,
    rt: AsyncRuntime<OS::FD, Env>,
}

impl<Env, OS> Node<Env, OS>
where
    OS: os::OperatingSystem,
{
    fn new(env: Env) -> Self {
        Self { os: OS::default(), rt: AsyncRuntime::new(env) }
    }

    fn create_stream(&mut self, cb: fn(env: &mut Env, fd: OS::FD)) {
        let task_id = self.rt.add(task::Task { on_create: cb });
        self.os.send(os::Input { task_id, args: os::IoArgs::Create });
        /* how can I get the output from the OS, and call the callback? */
    }
}

pub mod os {
    use crate::task;

    #[derive(Ord, PartialOrd, Eq, PartialEq)]
    pub enum IoArgs<FD> {
        Create,
        Read { fd: FD, buf: Vec<u8>, offset: usize },
        Append { fd: FD, data: Box<u8> },
        Delete(FD),
    }

    #[derive(Debug)]
    pub enum IoRetVal<FD: core::fmt::Debug> {
        Create(FD),
        Read(usize),
        Append(usize),
        Delete(bool),
    }

    #[derive(Ord, PartialOrd, Eq, PartialEq)]
    pub struct Input<FD> {
        pub task_id: task::ID,
        pub args: IoArgs<FD>,
    }

    pub struct Output<FD: core::fmt::Debug> {
        pub task_id: task::ID,
        pub ret_val: IoRetVal<FD>,
    }

    pub trait OperatingSystem: Default {
        type FD: core::fmt::Debug;
        fn send(&mut self, msg: Input<Self::FD>);
    }
}

mod task {
    use crate::os;
    pub type ID = u64;

    // We always know what type the function is at this point
    pub union Task<FD, Env> {
        pub on_create: fn(env: &mut Env, fd: FD),
    }
}

struct AsyncRuntime<FD, Env> {
    tasks: Vec<task::Task<FD, Env>>,
    recycled: Vec<task::ID>,
    /// Pointer to some mutable state, so the callback can effect
    /// the outside world.
    /// What Baker/Hewitt called "proper environment", AFAICT
    pub env: Env,
}

impl<FD, Env> AsyncRuntime<FD, Env> {
    fn new(env: Env) -> Self { Self { tasks: vec![], recycled: vec![], env } }

    fn add(&mut self, t: task::Task<FD, Env>) -> task::ID {
        match self.recycled.pop() {
            Some(task_id) => {
                self.tasks[task_id as usize] = t;
                task_id
            }
            None => {
                let task_id = self.tasks.len();
                self.tasks.push(t);
                task_id as task::ID
            }
        }
    }

    fn remove(&mut self, task_id: task::ID) -> &mut task::Task<FD, Env> {
        self.recycled.push(task_id);
        self.tasks.get_mut(task_id as usize).expect("task id to be valid")
    }
}

struct DB<FD, Env> {
    async_runtime: AsyncRuntime<FD, Env>,
}

impl<FD, Env> DB<FD, Env>
where
    FD: core::fmt::Debug,
{
    fn new(env: Env) -> Self { Self { async_runtime: AsyncRuntime::new(env) } }

    fn send(&mut self, os::Output { task_id, ret_val }: os::Output<FD>) {
        match ret_val {
            os::IoRetVal::Create(fd) => {
                let t = self.async_runtime.remove(task_id);
                let on_create = unsafe { t.on_create };
                on_create(&mut self.async_runtime.env, fd);
            }
            _ => panic!("TODO: handle receiving '{:?}' from OS", ret_val),
        }
    }

    fn create_stream(&mut self, cb: fn(env: &mut Env, fd: FD)) -> task::ID {
        self.async_runtime.add(task::Task { on_create: cb })
    }
}
