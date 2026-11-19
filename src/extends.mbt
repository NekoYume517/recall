// 保持 Scheduler 的点调用 API：0.1.20261117 起，trait impl 只有显式
// promotion 后才能作为方法调用。类型与 trait 同包，集中在这里声明，
// 避免 CLI、库和测试逐个改写已有的 scheduler.name()/init()/review() 调用。

///|
pub extend Fsrs with Scheduler::{
  name,
  init,
  review,
  retrievability,
  desired_retention,
}

///|
pub extend Sm2 with Scheduler::{
  name,
  init,
  review,
  retrievability,
  desired_retention,
}

///|
pub extend Leitner with Scheduler::{
  name,
  init,
  review,
  retrievability,
  desired_retention,
}

///|
pub extend AnyScheduler with Scheduler::{
  name,
  init,
  review,
  retrievability,
  desired_retention,
}
