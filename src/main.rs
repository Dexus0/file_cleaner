use nohash_hasher::IntMap as HashMap;
use std::fs::{read_dir, remove_file};
use std::io::{Error, ErrorKind};
use std::mem::MaybeUninit;
use std::path::{Path, PathBuf};

static mut DELETED: usize = 0;
static mut SCANNED: usize = 0;

static mut MAP: MaybeUninit<HashMap<usize, Vec<PathBuf>>> = MaybeUninit::uninit();

macro_rules! retry_interrupts {
    ($e:expr) => {
        loop {
            match $e {
                Ok(x) => break Ok(x),
                Err(err) => match err.kind() {
                    ErrorKind::Interrupted => continue, // Try $e again, if error == interrupted
                    _ => break Err(err),
                },
            }
        }
    };
}
fn main() -> Result<(), Error> {
    let dir = std::env::args_os().nth(1).unwrap_or_default();
    let paths = read_dir(dir)?.flatten().map(|x| x.path());

    remove_duplicates(paths);

    Ok(())
}

fn remove_duplicates(paths: impl Iterator<Item = PathBuf>) {
    unsafe {
        MAP = MaybeUninit::new(map_from_iter(&paths)); // initialize MAP before before asynchronous code
        print_scanned(SCANNED); // prints 0 for when no files were found
    }
    for cur_path in paths {
        scan_file(cur_path);
        unsafe {
            SCANNED += 1;
            print_scanned(SCANNED);
        }
    }

    unsafe {
        println!("\ndeleted: {}", DELETED);
    }
}

fn print_scanned(num: usize) {
    print!("\rscanned: {num}");
}

fn map_from_iter<K, V>(iter: &impl Iterator) -> HashMap<K, V> {
    use nohash_hasher::BuildNoHashHasher;
    use std::collections::HashMap;
    let tuple = iter.size_hint();

    let num = match tuple.1 {
        Some(size) => size,
        None => tuple.0,
    };

    HashMap::with_capacity_and_hasher(num, BuildNoHashHasher::default())
}

fn read_usize<P: AsRef<Path>>(path: P) -> Result<usize, Error> {
    use std::{fs::File, io::Read, mem::size_of};
    let mut buf = [0u8; size_of::<usize>()];

    match retry_interrupts!(File::open(&path))?.read_exact(&mut buf) {
        Ok(_) => Ok(usize::from_ne_bytes(buf)),
        Err(e) => Err(e),
    }
}

fn read<P: AsRef<Path>>(path: P) -> Result<Vec<u8>, Error> {
    use std::fs::read;
    retry_interrupts!(read(&path))
}

fn scan_file(cur_path: PathBuf) {
    let Ok(id) = read_usize(&cur_path) else {
        return;
    };

    let Some(paths) = (unsafe{MAP.assume_init_mut().get_mut(&id)}) else {
        unsafe{ MAP.assume_init_mut().insert(id, vec![cur_path]);}
        return;
    };

    let Ok(data) = read(&cur_path) else {
        return;
    };

    for old_path in paths.iter() {
        // Invalidates other iters if async:
        // if we exit the loop, another thread could lengthen the list—meaning this thread would no longer check all unique files with the same ID;
        // this file, and the recently added file could be a duplicate; if it is:
        // this thread will now add this file as another unique file, thusly leaving us with 2 identical files in the list of unique files.
        let Ok(other) = read(old_path) else {
            continue
        };

        if other == data {
            match remove_file(cur_path) {
                Ok(_) => unsafe { DELETED += 1 },
                Err(err) => eprintln!("{err}"),
            };
            return;
        }
    }
    paths.push(cur_path);
}
