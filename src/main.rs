/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

use nohash_hasher::IntMap as HashMap;
use std::fs::{read, read_dir, remove_file};
use std::io::{Error, ErrorKind};
use std::mem::{size_of, MaybeUninit};
use std::path::{Path, PathBuf};

static mut DELETED: usize = 0; // as long as program-local threading is used, any read/write should be safe
static mut SCANNED: usize = 0; // as long as program-local threading is used, any read/write should be safe
                               // I'm relatively certain we shouldn't have to worry about hardware reordering within 1 program.
                               // It's possible any form of concurrency is safe,
                               // as long as the threads only deal with 1 version of the variable (as in, there's no seperate value for each thread.)
                               // Beware of cache coherency issues when not using program-local threading.

type ID = usize;
const IDSIZE: usize = size_of::<ID>();

static mut MAP: MaybeUninit<HashMap<ID, Vec<PathBuf>>> = MaybeUninit::uninit();

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

    unsafe {
        // initialize MAP before asynchronous code
        MAP = MaybeUninit::new(map_from_iter(&paths));
    }
    remove_duplicates(paths);

    Ok(())
}

fn remove_duplicates(paths: impl Iterator<Item = PathBuf>) {
    unsafe {
        print_scanned(SCANNED); // prints 0 for when no files were found
    }
    for cur_path in paths {
        fn inner(cur_path: PathBuf) {
            scan_file(cur_path);
            unsafe {
                SCANNED += 1;
                print_scanned(SCANNED);
            }
        }
        inner(cur_path);
    }

    unsafe {
        println!("\ndeleted: {DELETED}");
    }
}

fn print_scanned(num: usize) {
    print!("\rscanned: {num}");
}

fn map_from_iter<K, V>(iter: &impl Iterator) -> HashMap<K, V> {
    use nohash_hasher::BuildNoHashHasher;
    use std::collections::HashMap;

    fn inner(size_hint: (usize, Option<usize>)) -> usize {
        match size_hint.1 {
            Some(size) => size,  // return upperbound hint
            None => size_hint.0, // return lowerbound hint
        }
    }
    let size_hint = iter.size_hint();
    let capacity = inner(size_hint);

    HashMap::with_capacity_and_hasher(capacity, BuildNoHashHasher::default())
}

fn read_id(path: &Path) -> Result<ID, Error> {
    use std::{fs::File, io::Read};

    let mut buf = [0u8; IDSIZE];

    match retry_interrupts!(File::open(path))?.read_exact(&mut buf) {
        Ok(()) => Ok(ID::from_ne_bytes(buf)),
        Err(e) => Err(e),
    }
}

fn scan_file(cur_path: PathBuf) {
    let Ok(id) = read_id(&cur_path) else {
        return;
    };

    let Some(paths) = unsafe { MAP.assume_init_mut() }.get_mut(&id) else {
        unsafe { MAP.assume_init_mut() }.insert(id, vec![cur_path]);
        return;
    };

    let Ok(data) = read(&cur_path) else {
        return;
    };

    for old_path in &*paths {
        // Invalidates other iters if async:
        // if we exit the loop, another thread could lengthen the list (not the iter); meaning this thread would no longer check all unique files with the same ID.
        // The recently added file could be a duplicate, if it is:
        // this thread will now add this file as another unique file, thusly leaving us with 2 identical files in the list of unique files.
        let Ok(other) = read(old_path) else { continue };

        if other == data {
            // should be async safe, as no edits are being made to MAP after.
            match retry_interrupts!(remove_file(&cur_path)) {
                Ok(()) => unsafe { DELETED += 1 },
                Err(err) => eprintln!("{err}"),
            };
            drop(cur_path); // cur_path is either removed or in an invalid state; drop it to make sure it can't be used.
            return;
        }
    }
    paths.push(cur_path);
}
