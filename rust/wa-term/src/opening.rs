//! The opening: rain, a tornado, and the header's star (Victor, 22/11).
//!
//! The reference is the sketch Fable and Victor iterated nine times
//! (`scratch/wa-header-demo8.py`): the whole terminal becomes green glyph rain, the rain is swept
//! into one big tornado, the tornado turns faster and shrinks into the header's star cell, and the
//! title is written in the alien alphabet and translated left to right - then the rest of the
//! header, unchanged. This module is that sequence and nothing else: it owns no screen, no clock and
//! no keys. `Opening::step` answers the bytes of the next frame and `Opening::delay` how long that
//! frame is held; the host's reader thread - the one thread that owns the terminal and the keys -
//! writes them, and ends the opening the moment a key arrives or the window changes size.
//!
//! Why the frames are a function of a step counter and not of the wall clock: a reader thread that is
//! descheduled must not make the animation skip into its end, and a test can walk the whole thing
//! without sleeping. The host still enforces the total budget (`TOTAL_MS`), so a starved thread can
//! shorten the opening but never lengthen it.
//!
//! It runs on the ALTERNATE screen, and every write the chat makes is held while it does (the host's
//! `terminal_editor::hold`). So what the reader ends up on is exactly the screen today's start writes
//! - the same bytes, in the same order - with no glyph left over and no scrollback moved.

/// How long the whole opening may take, keys aside. The sketch runs ~6 s on purpose; the CLI may not.
pub const TOTAL_MS: u64 = 2000;

/// The matrix green, FINAL at xterm 41 (`#00d75f`, Victor 22/11 21:33Z): the star of the welcome line
/// and the animated first glyph of the run status row both carry it, and the tornado's last turn burns
/// in it, so the star that lands is the star the header keeps.
pub const MATRIX: &str = "\x1b[1;38;2;0;215;95m";

/// The alien alphabet: ONE glyph per ASCII letter, so a word keeps its length and its shape. That is
/// what makes the rain read as an alphabet rather than as noise, and what lets the title be written in
/// it and then translated in place (docs/missions/reports/launch-opening.md). Every glyph is
/// East-Asian-Narrow (measured, see the report), so a translated word occupies the cells the real word
/// does.
pub const ALIEN: [char; 26] = ['\u{23c3}', '\u{23da}', '\u{260a}', '\u{2385}', '\u{27d2}', '\u{238e}',
    '\u{260c}', '\u{2291}', '\u{27df}', '\u{27ca}', '\u{260d}', '\u{2330}', '\u{22d4}', '\u{22cf}',
    '\u{235c}', '\u{233f}', '\u{237e}', '\u{2340}', '\u{2307}', '\u{23c1}', '\u{238d}', '\u{2390}',
    '\u{2359}', '\u{2316}', '\u{22ac}', '\u{22c9}'];

/// The alien glyph for one ASCII letter, or `None` for anything that is not one - a space, a mark, a
/// digit: the title's punctuation is not translated, which is what keeps it readable.
pub fn alien(letter: char) -> Option<char> {
    if !letter.is_ascii_alphabetic() { return None; }
    Some(ALIEN[(letter.to_ascii_lowercase() as u8 - b'a') as usize])
}

/// The bytes that take the alternate screen, blank it, and hide the cursor until the opening ends.
pub fn enter_bytes() -> &'static str { "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l" }

/// The bytes that give the screen back: the alternate screen left (which restores the reader's own
/// screen, cursor and all), the attributes cleared, the cursor shown. The same sequence the fullscreen
/// console leaves with, so a terminal that survives one survives the other.
pub fn leave_bytes() -> String { crate::scroll::screen::leave_bytes(crate::scroll::settings::Mode::Fullscreen) }

// ---- cells and colours --------------------------------------------------------------------------

/// One cell of a frame: the character and the index of the SGR run it is drawn in.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Cell { ch: char, sgr: u16 }

impl Default for Cell {
    fn default() -> Self { Cell { ch: ' ', sgr: PLAIN } }
}

// The first entries of the palette. 0 is plain; 1..=10 are the animation's own; everything the header
// carries is appended by `parse` as it is met, so the animation never re-invents a colour the view
// already chose.
const PLAIN: u16 = 0;
const HEAD: u16 = 1;
const STAR: u16 = 2;
const TRAIL: [u16; 4] = [3, 4, 5, 6];
const TORN_NEAR: u16 = 7;
const TORN_FAR: u16 = 8;
const DIM: u16 = 9;
const FLICKER: u16 = 10;

fn default_palette() -> [&'static str; 11] {
    ["\x1b[0m",
     "\x1b[1;38;2;255;255;255m",   // 1 a rain head: white, bold
     MATRIX,                        // 2 the star, and the near face of the tornado's foot
     "\x1b[38;2;0;255;65m",         // 3 the trails, brightest first
     "\x1b[38;2;0;215;65m",         // 4
     "\x1b[38;2;0;170;55m",         // 5
     "\x1b[38;2;0;130;45m",         // 6
     "\x1b[1;38;2;120;255;170m",   // 7 the tornado's near face
     "\x1b[38;2;0;200;80m",         // 8 its far face
     "\x1b[38;2;0;95;35m",          // 9 the dimmest trail
     "\x1b[1;38;2;180;255;200m"]    // 10 the cell being decoded
}

/// The frames of each act. The sketch spends 145 frames and 6 s on them; a CLI has two seconds, so
/// each act is compressed - and the title's translation is capped at `DECODE_FRAMES` beats whatever the
/// title's length, because a release tag can make it longer than the sketch's.
const RAIN_FRAMES: usize = 10;
const SWEEP_FRAMES: usize = 12;
const TORNADO_FRAMES: usize = 10;
const SHRINK_FRAMES: usize = 14;
const LAND_FRAMES: usize = 3;
const DECODE_FRAMES: usize = 24;

// ---- the random ------------------------------------------------------------------------------

/// A tiny deterministic RNG (xorshift64*): the same seed draws the same rain, which is what lets a test
/// assert on a frame without pinning a screenful of glyphs.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng { Rng(seed | 1) }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    /// A number in [0, 1).
    fn unit(&mut self) -> f32 { (self.next() >> 40) as f32 / (1u64 << 24) as f32 }
    fn below(&mut self, bound: usize) -> usize { (self.next() % bound.max(1) as u64) as usize }
    fn pick<T: Copy>(&mut self, from: &[T]) -> T { from[self.below(from.len())] }
}

// ---- what it draws ----------------------------------------------------------------------------

/// One column of rain: where its head is and how fast it falls.
#[derive(Clone, Copy)]
struct Head { y: f32, speed: f32 }

/// The rain: an age per cell (`None` = empty), the glyph in it, and one head per column.
struct Rain { age: Vec<Option<u8>>, glyph: Vec<char>, heads: Vec<Option<Head>> }

/// One grain of the tornado.
struct Particle { h: f32, theta: f32, w: f32, glyph: char, born: f32 }

/// The header as the view painted it.
struct Header {
    /// The banner's lines, parsed into cells: line 0 is the rule, line 1 the star and the title.
    lines: Vec<Vec<Cell>>,
    /// For each cell of line 1, the alien glyph to show until that cell is decoded (`None`: not a letter).
    alien: Vec<Option<char>>,
}

pub struct Opening {
    width: usize,
    height: usize,
    palette: Vec<String>,
    /// The glyphs the rain draws from: the alien alphabet, the digits, and half-width katakana.
    pool: Vec<char>,
    grid: Vec<Cell>,
    /// What the screen already holds, so a frame writes only what changed.
    shown: Vec<Cell>,
    rain: Rain,
    parts: Vec<Particle>,
    rng: Rng,
    t: f32,
    step: usize,
    header: Option<Header>,
    finished: bool,
}

impl Opening {
    /// A new opening for a console `width` x `height` cells big. `seed` fixes the rain: the host passes
    /// the clock, a test a constant.
    pub fn new(width: usize, height: usize, seed: u64) -> Opening {
        let width = width.max(1);
        let height = height.max(1);
        let palette: Vec<String> = default_palette().iter().map(|sgr| sgr.to_string()).collect();
        let mut pool: Vec<char> = ALIEN.to_vec();
        pool.extend('0'..='9');
        // Half-width katakana: one column each (measured - East Asian Width `H`, and every one of them
        // covered by the monospace fonts on this node). It is the sketch's rain and it stays.
        pool.extend('\u{ff66}'..='\u{ff9d}');
        let mut rng = Rng::new(seed);
        let mut rain = Rain { age: vec![None; width * height], glyph: vec![' '; width * height],
            heads: vec![None; width] };
        for head in rain.heads.iter_mut() {
            *head = if rng.unit() < 0.35 {
                Some(Head { y: -6.0 * rng.unit(), speed: 0.6 + 0.9 * rng.unit() })
            } else { None };
        }
        let count = ((width * height) as f32 * 0.11) as usize;
        let parts: Vec<Particle> = (0..count).map(|_| Particle {
            h: rng.unit(), theta: 6.283 * rng.unit(), w: 0.7 + 0.6 * rng.unit(),
            glyph: rng.pick(&pool), born: rng.unit() }).collect();
        Opening { width, height, palette, pool, grid: vec![Cell::default(); width * height],
            shown: vec![Cell::default(); width * height], rain, parts, rng, t: 0.0, step: 0,
            header: None, finished: false }
    }

    pub fn width(&self) -> usize { self.width }
    pub fn height(&self) -> usize { self.height }
    pub fn finished(&self) -> bool { self.finished }

    /// The header the view painted, as its lines: escapes and all. Until it arrives there is nothing to
    /// translate, so a slow start does not lengthen the opening - the star lands in its cell, the
    /// screen comes back, and the header is simply there, exactly as a start today writes it.
    pub fn header(&mut self, lines: &[String]) {
        let mut palette = std::mem::take(&mut self.palette);
        let mut parsed: Vec<Vec<Cell>> = lines.iter().map(|line| parse(line, &mut palette)).collect();
        for row in parsed.iter_mut() { row.truncate(self.width); }
        let mut letters = Vec::new();
        if let Some(title) = parsed.get(1) {
            for (index, cell) in title.iter().enumerate() {
                // The star and the one space after it are not a word: the title starts at cell 2.
                letters.push(if index < 2 { None } else { alien(cell.ch) });
            }
        }
        self.palette = palette;
        self.header = Some(Header { lines: parsed, alien: letters });
    }

    fn lines(&self) -> usize { self.header.as_ref().map(|header| header.lines.len()).unwrap_or(0) }
    fn title_cells(&self) -> usize { self.header.as_ref().map(|header| header.alien.len().saturating_sub(2)).unwrap_or(0) }
    fn acts(&self) -> usize { RAIN_FRAMES + SWEEP_FRAMES + TORNADO_FRAMES + SHRINK_FRAMES + LAND_FRAMES }

    /// How many cells of the title each frame of the translation decodes: one for a short title, several
    /// for a long one, so the translation always takes `DECODE_FRAMES` beats.
    fn stride(&self) -> usize { ((self.title_cells() + DECODE_FRAMES - 1) / DECODE_FRAMES).max(1) }

    /// The frames after the acts: the rule and the title in alien letters, the translation, then the rest
    /// of the block a line at a time (the last of those is also the frame it stops on).
    fn header_frames(&self) -> usize {
        if self.header.is_none() { return 0; }
        let decode = (self.title_cells() + self.stride() - 1) / self.stride();
        1 + decode + self.lines().saturating_sub(2)
    }

    /// Every frame this opening will draw (a test walks them all; `planned_ms` adds up their holds).
    pub fn frames(&self) -> usize { self.acts() + self.header_frames() }

    /// How long frame `index` is held.
    fn delay_at(&self, index: usize) -> u64 {
        let acts = self.acts();
        if index < RAIN_FRAMES + SWEEP_FRAMES + TORNADO_FRAMES { return 22; }
        if index < RAIN_FRAMES + SWEEP_FRAMES + TORNADO_FRAMES + SHRINK_FRAMES { return 20; }
        if index < acts { return 40; }
        let beat = index - acts;
        let decode = (self.title_cells() + self.stride() - 1) / self.stride();
        if beat == 0 { return 40; }
        if beat <= decode { return 16; }
        // The rest of the block, a line at a time; the frame it stops on is held long enough to be read
        // before the screen comes back (which shows the same picture, so the switch is invisible).
        if index + 1 == self.acts() + self.header_frames() { return 160; }
        30
    }

    /// How long the frame just produced is held.
    pub fn delay(&self) -> u64 { self.delay_at(self.step.saturating_sub(1)) }

    /// The whole opening's wall time: what `TOTAL_MS` has to cover, and a number a test can assert
    /// instead of trusting a stopwatch.
    pub fn planned_ms(&self) -> u64 { (0..self.frames()).map(|index| self.delay_at(index)).sum() }

    /// The next frame's bytes, or `None` once the opening is over. Every call advances the rain, the
    /// tornado or the header by exactly one frame.
    pub fn step(&mut self) -> Option<String> {
        if self.finished { return None; }
        let index = self.step;
        self.step += 1;
        let acts = self.acts();
        if index < acts {
            self.act_frame(index);
            return Some(self.render());
        }
        let beat = index - acts;
        let frames = self.header_frames();
        if beat >= frames { self.finished = true; return None; }
        // The header's beats. Everything the acts left on the grid goes: the rule and the title take the
        // screen the way the sketch's last beat does.
        for cell in self.grid.iter_mut() { *cell = Cell::default(); }
        let decode = (self.title_cells() + self.stride() - 1) / self.stride();
        let stride = self.stride();
        if beat == 0 {
            self.draw_header(0, 0, 2);
        } else if beat <= decode {
            self.draw_header((beat * stride).min(self.title_cells()), 3, 2);
        } else {
            let revealed = beat - decode;
            self.draw_header(self.title_cells(), 0, 2 + revealed);
        }
        if beat + 1 == frames { self.finished = true; }
        Some(self.render())
    }

    /// The acts: rain, the sweep into the tornado, the tornado, the shrink, the star landing.
    fn act_frame(&mut self, index: usize) {
        for cell in self.grid.iter_mut() { *cell = Cell::default(); }
        // The header's star sits on row 1, column 0: the sketch's STAR_Y, STAR_X.
        let star = (if self.height > 1 { 1 } else { 0 }, 0);
        if index < RAIN_FRAMES {
            self.rain_step(0.10);
            self.draw_rain(0.0);
            return;
        }
        let sweep = index - RAIN_FRAMES;
        if sweep < SWEEP_FRAMES {
            let f = sweep as f32;
            self.rain_step(0.10 * (1.0 - f / SWEEP_FRAMES as f32));
            self.draw_rain(f / (SWEEP_FRAMES as f32 * 3.3));
            self.draw_tornado(f / (SWEEP_FRAMES as f32 * 0.75), 1.0, star);
            self.t += 0.06;
            return;
        }
        let funnel = index - RAIN_FRAMES - SWEEP_FRAMES;
        if funnel < TORNADO_FRAMES {
            self.rain_step(0.0);
            self.draw_rain(0.75 + funnel as f32 / 80.0);
            self.draw_tornado(1.0, 1.0, star);
            self.t += 0.06;
            return;
        }
        let shrink = index - RAIN_FRAMES - SWEEP_FRAMES - TORNADO_FRAMES;
        if shrink < SHRINK_FRAMES {
            let a = (shrink + 1) as f32 / SHRINK_FRAMES as f32;
            let scale = (1.0 - a).powf(2.2);
            self.draw_tornado(1.0, scale, star);
            self.t += 0.06 + 0.10 * a;
            return;
        }
        // It lands: white, then the bright green of the trail, then the matrix green of the line.
        let land = index + LAND_FRAMES - self.acts();
        let colour = match land { 0 => HEAD, 1 => TRAIL[0], _ => STAR };
        self.put(star.0, star.1, '\u{273b}', colour);
    }

    // ---- the rain ----------------------------------------------------------------------------

    fn rain_step(&mut self, spawn: f32) {
        let (width, height) = (self.width, self.height);
        for index in 0..width * height {
            if let Some(age) = self.rain.age[index] {
                if age + 1 > 22 { self.rain.age[index] = None; }
                else {
                    self.rain.age[index] = Some(age + 1);
                    if self.rng.unit() < 0.03 { self.rain.glyph[index] = self.rng.pick(&self.pool); }
                }
            }
        }
        for x in 0..width {
            let mut head = match self.rain.heads[x] {
                Some(head) => head,
                None => {
                    if self.rng.unit() >= spawn { continue; }
                    Head { y: -6.0 * self.rng.unit(), speed: 0.6 + 0.9 * self.rng.unit() }
                }
            };
            let from = head.y.max(0.0) as usize;
            head.y += head.speed;
            let to = (head.y as usize + 1).min(height);
            for y in from..to {
                let index = y * width + x;
                self.rain.age[index] = Some(0);
                self.rain.glyph[index] = self.rng.pick(&self.pool);
            }
            self.rain.heads[x] = if head.y > height as f32 + 2.0 { None } else { Some(head) };
        }
    }

    fn draw_rain(&mut self, fade: f32) {
        let (width, height) = (self.width, self.height);
        for y in 0..height {
            for x in 0..width {
                let index = y * width + x;
                let Some(age) = self.rain.age[index] else { continue };
                if fade > 0.0 && self.rng.unit() < fade { continue; }
                let age = age as u32 + if fade > 0.75 { 10 } else { 0 };
                let colour = match age {
                    0 => HEAD,
                    1..=2 => TRAIL[0],
                    3..=7 => TRAIL[1],
                    8..=13 => TRAIL[2],
                    14..=18 => TRAIL[3],
                    _ => DIM,
                };
                self.put(y, x, self.rain.glyph[index], colour);
            }
        }
    }

    // ---- the tornado -------------------------------------------------------------------------

    fn draw_tornado(&mut self, grow: f32, scale: f32, star: (usize, usize)) {
        let (width, height) = (self.width, self.height);
        let radius = (width as f32 * 0.19).min(height as f32 * 0.95);
        let mut cells: Vec<((usize, usize), f32, u16, char)> = Vec::new();
        for part in &self.parts {
            if part.born > grow { continue; }
            let h = (part.h + self.t * 0.22 * part.w).rem_euclid(1.0);
            let y = (height as f32 - 1.0) - h * (height as f32 - 3.0).max(0.0);
            let rad = 1.0 + h.powf(1.3) * radius;
            let theta = part.theta + self.t * (5.5 - 3.2 * h) * part.w;
            let sway = (self.t * 1.1 + h * 2.6).sin() * width as f32 * 0.035;
            let x = width as f32 / 2.0 + sway + 2.0 * rad * theta.cos();
            let z = theta.sin();
            let row = star.0 as f32 + (y - star.0 as f32) * scale;
            let column = star.1 as f32 + (x - star.1 as f32) * scale;
            if row < 0.0 || column < 0.0 { continue; }
            let (row, column) = (row.round() as usize, column.round() as usize);
            if row >= height || column >= width { continue; }
            let colour = if scale < 0.35 {
                // The last turn burns bright, still in the matrix green - the star it becomes.
                if z > 0.0 { STAR } else { TRAIL[0] }
            } else if z > 0.5 { TORN_NEAR } else if z > -0.2 { TORN_FAR } else { DIM };
            cells.push(((row, column), z, colour, part.glyph));
        }
        // Near faces win: a grain in front draws over the one behind it in the same cell.
        cells.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        for ((row, column), _, colour, glyph) in cells { self.put(row, column, glyph, colour); }
    }

    // ---- the header --------------------------------------------------------------------------

    /// `k` cells of the title are translated, the next `flicker` are being decoded, and `lines` lines of
    /// the block are on the screen.
    fn draw_header(&mut self, k: usize, flicker: usize, lines: usize) {
        let Some(header) = self.header.take() else { return };
        for (row, cells) in header.lines.iter().enumerate() {
            if row >= lines || row >= self.height { break; }
            for (column, cell) in cells.iter().enumerate() {
                if column >= self.width { break; }
                let mut cell = *cell;
                if row == 1 && column >= 2 {
                    let index = column - 2;
                    if let Some(glyph) = header.alien.get(column).copied().flatten() {
                        if index >= k + flicker {
                            // Not decoded yet: the letter, in the alien alphabet.
                            cell.ch = glyph;
                        } else if index >= k {
                            // Being decoded: the same cell, flickering between the two.
                            cell.ch = glyph;
                            if self.rng.unit() < 0.5 { cell.sgr = FLICKER; }
                        }
                    }
                }
                self.put(row, column, cell.ch, cell.sgr);
            }
        }
        self.header = Some(header);
    }

    fn put(&mut self, row: usize, column: usize, ch: char, sgr: u16) {
        if row >= self.height || column >= self.width { return; }
        self.grid[row * self.width + column] = Cell { ch, sgr };
    }

    // ---- what the screen gets ---------------------------------------------------------------

    /// The frame as bytes: only the cells that changed since the last one, row by row, each run under its
    /// own SGR. A frame that changes nothing writes nothing.
    fn render(&mut self) -> String {
        let mut out = String::new();
        for row in 0..self.height {
            let mut column = 0;
            while column < self.width {
                let index = row * self.width + column;
                if self.grid[index] == self.shown[index] { column += 1; continue; }
                let sgr = self.grid[index].sgr;
                let start = column;
                let mut run = String::new();
                while column < self.width {
                    let index = row * self.width + column;
                    if self.grid[index] == self.shown[index] || self.grid[index].sgr != sgr { break; }
                    run.push(self.grid[index].ch);
                    column += 1;
                }
                out.push_str(&format!("\x1b[{};{}H{}{}", row + 1, start + 1, self.sgr_of(sgr), run));
            }
        }
        if !out.is_empty() { out.push_str("\x1b[0m"); }
        self.shown.copy_from_slice(&self.grid);
        out
    }

    fn sgr_of(&self, sgr: u16) -> &str {
        self.palette.get(sgr as usize).map(|text| text.as_str()).unwrap_or("\x1b[0m")
    }

    /// The plain text of the screen as it stands (a test's view of the frame; the screen has the same).
    pub fn text(&self) -> Vec<String> {
        (0..self.height).map(|row| {
            let mut line = String::new();
            for column in 0..self.width { line.push(self.grid[row * self.width + column].ch); }
            line.trim_end().to_string()
        }).collect()
    }

    /// The SGR of one cell (a test's check that the star really is the matrix green).
    pub fn sgr_at(&self, row: usize, column: usize) -> String {
        if row >= self.height || column >= self.width { return String::new(); }
        self.sgr_of(self.grid[row * self.width + column].sgr).to_string()
    }
}

// ---- the header's escapes ---------------------------------------------------------------------

/// Split a painted line into cells, keeping each cell's SGR: the animation draws the header EXACTLY as
/// the view painted it, so the last frame of the alternate screen and the first frame of the real one
/// are the same picture and the switch is invisible.
fn parse(line: &str, palette: &mut Vec<String>) -> Vec<Cell> {
    let mut cells = Vec::new();
    let mut sgr = String::new();
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            let mut sequence = String::from("\u{1b}");
            if chars.peek() == Some(&'[') {
                sequence.push(chars.next().unwrap());
                for next in chars.by_ref() {
                    sequence.push(next);
                    if ('@'..='~').contains(&next) { break; }
                }
                if sequence.ends_with('m') { sgr = sequence; }
            }
            continue;
        }
        let index = match palette.iter().position(|known| known == &sgr) {
            Some(index) => index,
            None => { palette.push(sgr.clone()); palette.len() - 1 }
        };
        cells.push(Cell { ch, sgr: index as u16 });
    }
    cells
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header() -> Vec<String> {
        vec![format!("\x1b[38;2;136;136;136m{}\x1b[0m", "\u{2500}".repeat(40)),
            format!("{}\u{273b}\x1b[0m Welcome to \x1b[1mwasm-agent\x1b[0m!\x1b[38;2;153;153;153m v1.0 \u{b7} v23791f56\x1b[0m", MATRIX),
            String::new(),
            "\x1b[38;2;153;153;153m/help for help, /login to sign in to a provider\x1b[0m".to_string(),
            String::new(),
            "\x1b[38;2;153;153;153mcwd: /home/victor\x1b[0m".to_string()]
    }

    fn run_all(opening: &mut Opening) -> usize {
        let mut frames = 0;
        while opening.step().is_some() { frames += 1; }
        frames
    }

    #[test]
    fn the_alien_table_is_one_glyph_per_letter_and_no_glyph_twice() {
        assert_eq!(ALIEN.len(), 26, "a to z, one glyph each");
        let mut seen: Vec<char> = ALIEN.to_vec();
        seen.sort();
        seen.dedup();
        assert_eq!(seen.len(), 26, "two letters sharing a glyph is not an alphabet: {ALIEN:?}");
        assert_eq!(alien('a'), Some(ALIEN[0]));
        assert_eq!(alien('Z'), Some(ALIEN[25]), "a capital is its letter too");
        assert_eq!(alien(' '), None, "a space stays a space");
        assert_eq!(alien('!'), None);
        assert_eq!(alien('7'), None);
    }

    #[test]
    fn the_first_frames_are_rain_over_the_whole_screen() {
        let mut opening = Opening::new(80, 24, 7);
        let mut painted = 0;
        for _ in 0..RAIN_FRAMES {
            let bytes = opening.step().expect("a rain frame");
            assert!(bytes.contains("\x1b["), "a frame addresses the screen: {bytes:?}");
            painted += opening.text().iter().map(|row| row.chars().filter(|c| *c != ' ').count()).sum::<usize>();
        }
        assert!(painted > 100, "the rain covers the screen, not one row: {painted} cells");
        let all = opening.text().join("\n");
        assert!(!all.contains("Welcome"), "and it is glyphs, not the header: {all:?}");
    }

    #[test]
    fn the_tornado_is_one_funnel_with_a_narrow_foot_and_a_wide_crown() {
        let mut opening = Opening::new(90, 26, 11);
        // Walk into the middle of the tornado act and measure how wide each row it covers is.
        for _ in 0..RAIN_FRAMES + SWEEP_FRAMES + 4 { opening.step(); }
        let rows = opening.text();
        let drawn: Vec<&String> = rows.iter().filter(|row| !row.trim().is_empty()).collect();
        assert!(drawn.len() > 6, "the funnel spans many rows: {rows:?}");
        let ends = |row: &String| {
            let left = row.len() - row.trim_start().len();
            let right = row.trim_end().len();
            right - left
        };
        let crown = ends(drawn[0]);
        let foot = drawn.iter().map(|row| ends(row)).min().unwrap_or(0);
        assert!(crown > foot, "the crown is wider than the foot (crown {crown}, foot {foot}): {rows:?}");
    }

    #[test]
    fn the_last_frame_is_the_header_the_view_painted() {
        let mut opening = Opening::new(80, 24, 3);
        opening.header(&header());
        let frames = run_all(&mut opening);
        assert_eq!(frames, opening.frames(), "every frame the plan promised was drawn");
        let screen = opening.text();
        assert_eq!(screen[0], "\u{2500}".repeat(40), "the rule, at its own width");
        assert!(screen[1].starts_with("\u{273b} Welcome to wasm-agent! v1.0 \u{b7} v23791f56"),
            "the title is translated back: {:?}", screen[1]);
        assert_eq!(opening.sgr_at(1, 0), MATRIX, "and its star is the matrix green");
        assert!(screen[3].starts_with("/help for help"), "the rest of the block follows: {:?}", screen[3]);
        assert!(screen[5].starts_with("cwd: "), "line by line: {:?}", screen[5]);
    }

    #[test]
    fn the_title_is_alien_letters_until_it_is_decoded_and_it_keeps_its_cells() {
        let mut opening = Opening::new(80, 24, 3);
        opening.header(&header());
        for _ in 0..opening.acts() { opening.step(); }
        opening.step();
        let screen = opening.text();
        let row = &screen[1];
        assert_eq!(row.chars().count(), 41, "the title keeps its cells: {row:?}");
        assert!(row.contains(ALIEN[22]), "'w' is its alien glyph at the start: {row:?}");
        assert!(!row.contains("Welcome"), "nothing is decoded yet: {row:?}");
        assert!(row.contains("23791"), "the version's digits are not letters: {row:?}");
    }

    #[test]
    fn a_frame_writes_only_what_changed() {
        let mut opening = Opening::new(80, 24, 5);
        opening.header(&header());
        for _ in 0..opening.acts() + 1 { opening.step(); }
        // One beat of the translation moves the title row and nothing else.
        let next = opening.step().expect("a translated frame");
        assert!(next.len() < 400, "one row of a title, not a screenful: {} bytes", next.len());
        assert!(!next.contains("\x1b[1;1H"), "the rule did not move");
    }

    #[test]
    fn the_whole_opening_fits_the_budget() {
        let mut opening = Opening::new(120, 40, 9);
        opening.header(&header());
        let planned = opening.planned_ms();
        assert!(planned <= TOTAL_MS, "the plan is inside the 2 s budget: {planned} ms");
        assert!(planned > TOTAL_MS / 2, "and it is not a blink: {planned} ms");
    }

    #[test]
    fn a_longer_header_cannot_push_the_opening_past_the_budget() {
        // A release tag makes the title longer, and `unfinished` adds three lines: the translation is
        // capped at DECODE_FRAMES beats whatever the title's length.
        let mut opening = Opening::new(120, 40, 9);
        let mut long = header();
        long[1] = format!("{MATRIX}\u{273b}\x1b[0m Welcome to wasm-agent! v1.0 \u{b7} v1.2.3-rc.1234+abcdef0123456789");
        for _ in 0..3 { long.push("\x1b[38;2;255;193;7m! unfinished a run was cut off\x1b[0m".to_string()); }
        opening.header(&long);
        assert!(opening.planned_ms() <= TOTAL_MS, "{} ms", opening.planned_ms());
    }

    #[test]
    fn without_a_header_the_opening_ends_after_the_acts() {
        let mut opening = Opening::new(80, 24, 4);
        assert_eq!(run_all(&mut opening), opening.acts());
        assert!(opening.finished());
        assert!(opening.step().is_none(), "a finished opening draws nothing more");
    }

    #[test]
    fn the_header_arriving_late_still_gets_translated() {
        // The view composes the banner after the opening has started (it needs the model and the
        // session). The frames that ran before it arrived cost only their own beats.
        let mut opening = Opening::new(80, 24, 6);
        for _ in 0..RAIN_FRAMES { opening.step(); }
        opening.header(&header());
        assert!(run_all(&mut opening) + RAIN_FRAMES > opening.acts());
        assert!(opening.text()[1].contains("Welcome to wasm-agent!"));
    }
}
