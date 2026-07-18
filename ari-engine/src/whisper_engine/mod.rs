pub mod acceleration;
pub mod parallel_processor;
pub mod system_monitor;
pub mod whisper_engine;

pub use acceleration::*;
pub use parallel_processor::*;
pub use system_monitor::*;
pub use whisper_engine::*;

use std::sync::Arc;
use tokio::sync::RwLock;

// Global state for parallel processor
pub struct ParallelProcessorState {
    pub processor: Arc<RwLock<Option<ParallelProcessor>>>,
    pub system_monitor: Arc<SystemMonitor>,
}

impl ParallelProcessorState {
    pub fn new() -> Self {
        Self {
            processor: Arc::new(RwLock::new(None)),
            system_monitor: Arc::new(SystemMonitor::new()),
        }
    }
}
