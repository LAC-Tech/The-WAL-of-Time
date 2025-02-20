#[no_std]
extern crate alloc;

use alloc::vec::Vec;

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

    pub trait OperatingSystem<Receiver: FnMut(Output<Self::FD>)> {
        type FD: core::fmt::Debug;
        type Env;
        fn new(on_receive: Receiver) -> Self;
        fn send(&mut self, env: &mut Self::Env, msg: Input<Self::FD>);
    }
}

mod task {
    use crate::os;
    pub type ID = u64;

    // We always know what type the function is at this point
    pub union Task<OS: os::OperatingSystem<_>> {
        pub create: fn(env: &mut OS::Env, fd: OS::FD),
    }
}

struct AsyncRuntime<OS: os::OperatingSystem<R>, R> {
    tasks: Vec<task::Task<OS>>,
    recycled: Vec<task::ID>,
    /// Pointer to some mutable state, so the callback can effect
    /// the outside world.
    /// What Baker/Hewitt called "proper environment", AFAICT
    pub env: OS::Env,
}

impl<R: FnMut(os::Output<OS::FD>), OS: os::OperatingSystem<R>>
    AsyncRuntime<OS, R>
{
    fn new(env: OS::Env) -> Self {
        Self { tasks: vec![], recycled: vec![], env }
    }

    fn add(&mut self, t: task::Task<OS>) -> task::ID {
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

    fn remove(&mut self, task_id: task::ID) -> &mut task::Task<OS> {
        self.recycled.push(task_id);
        self.tasks.get_mut(task_id as usize).expect("task id to be valid")
    }
}

struct DB<OS: os::OperatingSystem> {
    async_runtime: AsyncRuntime<OS, R>,
    os: OS,
}

impl<OS: os::OperatingSystem> DB<OS> {
    fn new(env: OS::Env) -> Self {
        let mut async_runtime = AsyncRuntime::new(env);
        let on_receive = |os::Output { task_id, ret_val }| match ret_val {
            os::IoRetVal::Create(fd) => {
                let t = async_runtime.remove(task_id);
                let on_create = unsafe { t.create };
                on_create(&mut async_runtime.env, fd);
            }
            _ => panic!("TODO: handle receiving '{:?}' from OS", ret_val),
        };

        let os = OS::new(on_receive);

        Self { async_runtime, os }
    }

    fn create_stream(&mut self, cb: fn(env: &mut OS::Env, fd: OS::FD)) {
        let task_id = self.async_runtime.add(task::Task { create: cb });

        self.os.send(
            &mut self.async_runtime.env,
            os::Input { task_id, args: os::IoArgs::Create },
        )
    }
}
