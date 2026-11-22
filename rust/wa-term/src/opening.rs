//! The opening: rain, a supernova, and the header's star (Victor, 22/11).
//!
//! The reference is the sketch Victor chose after ten demos (`scratch/wa-header-demo10.py`, 22/11
//! 23:32Z - the 3D supernova, his favourite of the two): the whole terminal becomes green glyph rain,
//! a point of light ignites in the middle of it and flashes, a sphere of glyph debris flies apart in
//! depth, ONE ring races outward in a tilted plane (its near arc solid and bright, its far arc faint)
//! and blows the rain away as it passes, the cloud and the ring keep turning, everything falls into
//! the header's star cell, and the title is written in the alien alphabet and translated left to right
//! - then the rest of the header, unchanged. This module is that sequence and nothing else: it owns no
//! screen, no clock and no keys. `Opening::step` answers the bytes of the next frame and `Opening::delay` how long that
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
/// and the animated first glyph of the run status row both carry it, and the ring's leading edge burns
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
const NOVA_NEAR: u16 = 7;
const NOVA_FAR: u16 = 8;
const DIM: u16 = 9;
const FLICKER: u16 = 10;

fn default_palette() -> [&'static str; 11] {
    ["\x1b[0m",
     "\x1b[1;38;2;255;255;255m",   // 1 a rain head: white, bold
     MATRIX,                        // 2 the star, and the ring's leading edge
     "\x1b[38;2;0;255;65m",         // 3 the trails, brightest first
     "\x1b[38;2;0;215;65m",         // 4
     "\x1b[38;2;0;170;55m",         // 5
     "\x1b[38;2;0;130;45m",         // 6
     "\x1b[1;38;2;120;255;170m",   // 7 the supernova's near face
     "\x1b[38;2;0;200;80m",         // 8 the ring's far arc
     "\x1b[38;2;0;95;35m",          // 9 the dimmest trail
     "\x1b[1;38;2;180;255;200m"]    // 10 the cell being decoded
}

/// The frames of each act, in order: rain, the star igniting, the supernova, the cloud hanging and
/// turning, everything falling into the star cell, and the star landing. The sketch spends ~145 frames
/// and 6 s on them; a CLI has two seconds, so each act is compressed - and the title's translation is
/// capped at `DECODE_FRAMES` beats whatever the title's length, because a release tag can make it
/// longer than the sketch's.
const RAIN_FRAMES: usize = 8;
const IGNITE_FRAMES: usize = 6;
const NOVA_FRAMES: usize = 22;
const HANG_FRAMES: usize = 8;
const COLLAPSE_FRAMES: usize = 12;
const LAND_FRAMES: usize = 3;
const DECODE_FRAMES: usize = 24;

/// The ring's plane: tipped toward the reader, and a little askew, so its near arc is solid and bright
/// and its far arc is a line of faint dots - the sketch's TILT and ROLL.
const TILT: f32 = 0.42;
const ROLL: f32 = 0.22;

/// The star ignites on these, growing, in the middle of the rain (the sketch's `\u{b7}\u{b7}\u{2022}\u{2022}\u{25cf}\u{25cf}\u{2739}\u{2739}`).
const IGNITION: [char; 8] = ['\u{b7}', '\u{b7}', '\u{2022}', '\u{2022}', '\u{25cf}', '\u{25cf}', '\u{2739}', '\u{2739}'];

/// The ring's three bands: how far behind the leading edge each sits, and the glyphs it is made of -
/// solid where it is in front and a light shade where it is behind, which is what makes ONE plane read
/// as a plane.
const BANDS: [(f32, [char; 2]); 3] = [(0.0, ['\u{2588}', '\u{2593}']),
    (-0.9, ['\u{2593}', '\u{2592}']), (-1.8, ['\u{2592}', '\u{2591}'])];

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

/// One grain of the supernova: a direction on the unit sphere, how far out it flies, and the glyph it is
/// drawn with.
struct Point { u: (f32, f32, f32), v: f32, glyph: char }

/// One lit cell of a supernova frame, before it is rounded onto the grid.
struct Lit { row: f32, col: f32, z: f32, sgr: u16, ch: char }

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
    /// The supernova's debris, the geometry its camera and its ring need, and how far it has turned.
    points: Vec<Point>,
    ring: f32,
    cam: f32,
    centre: (f32, f32),
    rot: f32,
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
        let count = ((width * height) as f32 * 0.075) as usize;
        let ring = (width as f32 * 0.20).min(height as f32 * 0.72);
        let centre = (height as f32 / 2.0, width as f32 / 2.0);
        let points: Vec<Point> = (0..count).map(|_| {
            // A direction on the unit sphere, evenly: z uniform, the angle round it uniform.
            let z = -1.0 + 2.0 * rng.unit();
            let theta = 6.283 * rng.unit();
            let s = (1.0 - z * z).max(0.0).sqrt();
            Point { u: (s * theta.cos(), s * theta.sin(), z), v: (0.2 + 0.8 * rng.unit()).powf(0.6),
                glyph: rng.pick(&pool) }
        }).collect();
        Opening { width, height, palette, pool, grid: vec![Cell::default(); width * height],
            shown: vec![Cell::default(); width * height], rain, points, ring, cam: ring * 3.2, centre, rot: 0.0, rng, t: 0.0, step: 0,
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
    fn acts(&self) -> usize { RAIN_FRAMES + IGNITE_FRAMES + NOVA_FRAMES + HANG_FRAMES + COLLAPSE_FRAMES + LAND_FRAMES }

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
        if index < RAIN_FRAMES { return 22; }
        if index - RAIN_FRAMES < IGNITE_FRAMES { return 25; }
        if index - RAIN_FRAMES - IGNITE_FRAMES < NOVA_FRAMES { return 20; }
        if index - RAIN_FRAMES - IGNITE_FRAMES - NOVA_FRAMES < HANG_FRAMES { return 20; }
        if index - RAIN_FRAMES - IGNITE_FRAMES - NOVA_FRAMES - HANG_FRAMES < COLLAPSE_FRAMES { return 18; }
        if index < acts { return 40; }
        let beat = index - acts;
        let decode = (self.title_cells() + self.stride() - 1) / self.stride();
        if beat == 0 { return 40; }
        if beat <= decode { return 16; }
        // The rest of the block, a line at a time; the frame it stops on is held long enough to be read
        // before the screen comes back (which shows the same picture, so the switch is invisible).
        if index + 1 == self.acts() + self.header_frames() { return 120; }
        30
    }

    /// How long the frame just produced is held.
    pub fn delay(&self) -> u64 { self.delay_at(self.step.saturating_sub(1)) }

    /// The whole opening's wall time: what `TOTAL_MS` has to cover, and a number a test can assert
    /// instead of trusting a stopwatch.
    pub fn planned_ms(&self) -> u64 { (0..self.frames()).map(|index| self.delay_at(index)).sum() }

    /// The next frame's bytes, or `None` once the opening is over. Every call advances the rain, the
    /// supernova or the header by exactly one frame.
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

    /// The acts: rain, the star igniting, the supernova (flash, a sphere of debris in depth, ONE ring
    /// racing out in a tilted plane), the cloud hanging and turning, everything falling into the star
    /// cell, and the star landing.
    fn act_frame(&mut self, index: usize) {
        for cell in self.grid.iter_mut() { *cell = Cell::default(); }
        // The header's star sits on row 1, column 0: the sketch's STAR_Y, STAR_X.
        let star = (if self.height > 1 { 1 } else { 0 }, 0);
        if index < RAIN_FRAMES {
            self.rain_step(0.10);
            self.draw_rain(0.0);
            return;
        }
        let ignite = index - RAIN_FRAMES;
        if ignite < IGNITE_FRAMES {
            self.rain_step(0.10);
            self.draw_rain(0.0);
            let at = (ignite * IGNITION.len() / IGNITE_FRAMES).min(IGNITION.len() - 1);
            self.put_f(self.centre.0, self.centre.1, IGNITION[at], HEAD);
            return;
        }
        let nova = index - RAIN_FRAMES - IGNITE_FRAMES;
        if nova < NOVA_FRAMES {
            self.rain_step(0.0);
            let a = (nova + 1) as f32 / NOVA_FRAMES as f32;
            let (cells, reach) = self.scene(a, self.rot);
            self.scour(reach * 1.05);
            self.draw_rain(0.0);
            self.draw_scene(cells);
            // The flash is the newest light, so it is stamped on top of the debris it throws.
            if nova < 2 { self.flash(); }
            self.rot += 0.035;
            return;
        }
        let hang = index - RAIN_FRAMES - IGNITE_FRAMES - NOVA_FRAMES;
        if hang < HANG_FRAMES {
            self.rain_step(0.0);
            let (cells, reach) = self.scene(1.0, self.rot);
            self.scour(reach * 1.05);
            self.draw_rain(0.0);
            self.draw_scene(cells);
            self.rot += 0.045;
            return;
        }
        let falling = index - RAIN_FRAMES - IGNITE_FRAMES - NOVA_FRAMES - HANG_FRAMES;
        if falling < COLLAPSE_FRAMES {
            let a = (falling + 1) as f32 / COLLAPSE_FRAMES as f32;
            let (cells, _) = self.scene(1.0, self.rot);
            self.collapse(a, cells, star);
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

    // ---- the supernova -----------------------------------------------------------------------
    //
    // The sketch's `scene()`: world units are terminal ROWS, the camera looks down +z, a point is drawn
    // at x*2 columns (a cell is twice as tall as wide) and scaled by its distance, and its depth picks
    // both its brightness and its glyph. One bright band is ONE ring in one tilted plane, racing out;
    // the near arc is solid and bright and the far arc is a line of faint dots, which is what makes the
    // ring read as a plane rather than as a hoop.

    fn project(&self, x: f32, y: f32, z: f32) -> (f32, f32, f32) {
        let k = self.cam / (self.cam + z);
        (self.centre.0 + y * k, self.centre.1 + 2.0 * x * k, z)
    }

    /// The tilted plane the ring lives in.
    fn tip(x: f32, y: f32, z: f32) -> (f32, f32, f32) {
        let (c, s) = (TILT.cos(), TILT.sin());
        let (y, z) = (y * c - z * s, y * s + z * c);
        let (c, s) = (ROLL.cos(), ROLL.sin());
        let (x, y) = (x * c - y * s, x * s + y * c);
        (x, y, z)
    }

    fn turn(x: f32, y: f32, z: f32, rot: f32) -> (f32, f32, f32) {
        let (c, s) = (rot.cos(), rot.sin());
        (x * c + z * s, y, -x * s + z * c)
    }

    /// The whole explosion at progress `a` (0..1), and how far the ring has reached.
    fn scene(&self, a: f32, rot: f32) -> (Vec<Lit>, f32) {
        let mut cells = Vec::new();
        let grow = 1.0 - (1.0 - a).powi(3);
        let cloud = self.ring * 1.45;
        for point in &self.points {
            let (ux, uy, uz) = point.u;
            let r = point.v * cloud * grow;
            let (x, y, z) = Self::turn(ux * r, uy * r, uz * r, rot);
            let (row, col, z) = self.project(x, y, z);
            let near = -z / cloud;
            let (sgr, ch) = if a < 0.15 {
                (HEAD, point.glyph)
            } else if near > 0.35 {
                (if a < 0.6 { NOVA_NEAR } else { TRAIL[0] }, point.glyph)
            } else if near > -0.25 {
                (if a < 0.75 { TRAIL[1] } else { TRAIL[2] }, point.glyph)
            } else {
                // Far behind: a dim DOT, which is what reads as depth rather than as noise.
                (if a < 0.75 { TRAIL[3] } else { DIM }, '\u{b7}')
            };
            cells.push(Lit { row, col, z, sgr, ch });
        }
        let reach = self.ring * (1.0 - (1.0 - a).powf(2.4));
        for (band, (dr, glyphs)) in BANDS.iter().enumerate() {
            let r = reach + *dr;
            if r < 0.6 { continue; }
            let n = (r * 11.0) as i32;
            for index in 0..n {
                let angle = 6.283 * index as f32 / n as f32 + rot * 1.6;
                let (x, y, z) = Self::tip(r * angle.cos(), 0.0, r * angle.sin());
                let (row, col, z) = self.project(x, y, z);
                let front = z < 0.0;
                let sgr = if front {
                    if band == 0 && a < 0.55 { HEAD } else if band < 2 { NOVA_NEAR } else { TRAIL[0] }
                } else if band == 0 { TRAIL[2] } else { DIM };
                let ch = if front { glyphs[index as usize % 2] } else { '\u{2591}' };
                // The near arc sits in front of the cloud it is blowing away.
                cells.push(Lit { row, col, z: z - 0.5, sgr, ch });
            }
        }
        (cells, 2.0 * reach)
    }

    /// The cells, nearest last, so a grain in front draws over the one behind it in the same cell.
    fn draw_scene(&mut self, mut cells: Vec<Lit>) {
        cells.sort_by(|a, b| b.z.partial_cmp(&a.z).unwrap_or(std::cmp::Ordering::Equal));
        for lit in cells { self.put_f(lit.row, lit.col, lit.ch, lit.sgr); }
    }

    /// The ring blows the rain away as it passes: everything inside `rad` is gone.
    fn scour(&mut self, rad: f32) {
        let (width, height) = (self.width, self.height);
        let (centre_row, centre_col) = self.centre;
        for y in 0..height {
            for x in 0..width {
                let dy = (y as f32 - centre_row) * 2.0;
                if self.rain.age[y * width + x].is_some()
                    && (dy * dy + (x as f32 - centre_col).powi(2)).sqrt() < rad {
                    self.rain.age[y * width + x] = None;
                }
            }
        }
    }

    fn put_f(&mut self, row: f32, col: f32, ch: char, sgr: u16) {
        if row < 0.0 || col < 0.0 { return; }
        self.put(row.round() as usize, col.round() as usize, ch, sgr);
    }

    /// The flash: a filled disc of white light at the centre, for the first two frames of the supernova.
    fn flash(&mut self) {
        let (centre_row, centre_col) = self.centre;
        for dy in -3..=3 {
            for dx in -7..=7 {
                if ((dy as f32 * 2.0).powi(2) + (dx as f32).powi(2)).sqrt() < 7.0 {
                    self.put_f(centre_row + dy as f32, centre_col + dx as f32, '\u{2588}', HEAD);
                }
            }
        }
    }

    /// Everything falls into the header's star cell, with a last turn as it goes (the sketch's collapse).
    fn collapse(&mut self, a: f32, cells: Vec<Lit>, star: (usize, usize)) {
        let s = (1.0 - a).powf(2.4);
        let mut moved = Vec::with_capacity(cells.len());
        for lit in cells {
            let turn = (1.0 - s) * 0.9 * if lit.z < 0.0 { 1.0 } else { -1.0 };
            let dy = (lit.row - star.0 as f32) * 2.0;
            let dx = lit.col - star.1 as f32;
            let row = star.0 as f32 + (dy * turn.cos() - dx * turn.sin()) * s * 0.5;
            let col = star.1 as f32 + (dx * turn.cos() + dy * turn.sin()) * s;
            // The last frames are a point of light again, still white.
            let sgr = if s < 0.12 { HEAD } else { lit.sgr };
            moved.push(Lit { row, col, z: lit.z, sgr, ch: lit.ch });
        }
        self.draw_scene(moved);
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
    fn a_point_of_light_ignites_in_the_middle_of_the_rain() {
        let mut opening = Opening::new(80, 24, 11);
        for _ in 0..RAIN_FRAMES { opening.step(); }
        opening.step();
        let centre = (opening.centre.0.round() as usize, opening.centre.1.round() as usize);
        let glyph = opening.text()[centre.0].chars().nth(centre.1).unwrap_or(' ');
        assert!(IGNITION.contains(&glyph), "the middle of the screen is the star igniting, not rain: {glyph:?}");
        assert_eq!(opening.sgr_at(centre.0, centre.1), opening.sgr_of(HEAD), "and it is white");
        let painted: usize = opening.text().iter().map(|row| row.chars().filter(|c| *c != ' ').count()).sum();
        assert!(painted > 100, "with the rain still falling around it: {painted} cells");
    }

    #[test]
    fn the_supernova_flashes_and_blows_a_sphere_of_glyphs_apart() {
        let mut opening = Opening::new(90, 26, 12);
        for _ in 0..RAIN_FRAMES + IGNITE_FRAMES { opening.step(); }
        // The flash: a filled disc of light where the star was.
        opening.step();
        let rows = opening.text();
        let centre = (opening.centre.0.round() as usize, opening.centre.1.round() as usize);
        let flash: usize = rows[centre.0 - 1..=centre.0 + 1].iter()
            .map(|row| row.chars().skip(centre.1 - 6).take(13).filter(|c| *c == '\u{2588}').count()).sum();
        assert!(flash >= 20, "the flash is a disc of light, not one cell: {flash} blocks: {rows:?}");
        // Then the debris flies apart: the lit cells reach the edges of a wide screen.
        let mut reach = 0usize;
        for _ in 0..NOVA_FRAMES - 1 {
            opening.step();
            let rows = opening.text();
            let left = rows.iter().filter_map(|row| row.find(|c: char| c != ' ')).min().unwrap_or(80);
            let right = rows.iter().map(|row| row.trim_end().chars().count()).max().unwrap_or(0);
            reach = reach.max(right.saturating_sub(left));
        }
        assert!(reach > 40, "the debris is blown across the screen, not a small blob: {reach} columns");
    }

    #[test]
    fn the_ring_is_one_band_in_one_tilted_plane_with_a_bright_near_arc() {
        let mut opening = Opening::new(100, 30, 13);
        for _ in 0..RAIN_FRAMES + IGNITE_FRAMES + NOVA_FRAMES - 3 { opening.step(); }
        opening.step();
        let ring: Vec<char> = BANDS.iter().flat_map(|(_, glyphs)| glyphs.iter().copied()).collect();
        let rows = opening.text();
        let mut cells = Vec::new();
        let mut near = 0;
        let mut far = 0;
        for (y, row) in rows.iter().enumerate() {
            for (x, ch) in row.chars().enumerate() {
                if !ring.contains(&ch) { continue; }
                cells.push((y, x));
                let sgr = opening.sgr_at(y, x);
                if sgr == opening.sgr_of(NOVA_NEAR).to_string() || sgr == opening.sgr_of(HEAD).to_string() {
                    near += 1;
                }
                if sgr == opening.sgr_of(DIM).to_string() || sgr == opening.sgr_of(TRAIL[2]).to_string() {
                    far += 1;
                }
            }
        }
        assert!(cells.len() > 60, "the ring is made of many cells: {}", cells.len());
        let rows_used = cells.iter().map(|(y, _)| *y).max().unwrap() - cells.iter().map(|(y, _)| *y).min().unwrap();
        let cols_used = cells.iter().map(|(_, x)| *x).max().unwrap() - cells.iter().map(|(_, x)| *x).min().unwrap();
        // ONE band, not a filled disc: a band's cells are a small share of the box it spans.
        let share = cells.len() as f32 / ((rows_used + 1) * (cols_used + 1)) as f32;
        assert!(share < 0.45, "a band, not a filled disc: {:.0}% of its own box", share * 100.0);
        assert!(rows_used >= 6 && cols_used >= 30, "and it is a ring across the screen: {rows_used} rows, {cols_used} columns");
        assert!(near > 5 && far > 5, "a near arc and a far arc, both there: {near} near, {far} far");
        assert!(near > far || far > 0, "the near arc is not the only one drawn (far {far})");
    }

    #[test]
    fn everything_falls_into_the_stars_cell_and_the_star_lands_in_it() {
        let mut opening = Opening::new(90, 26, 14);
        opening.header(&header());
        let acts = opening.acts();
        for _ in 0..acts - LAND_FRAMES - COLLAPSE_FRAMES { opening.step(); }
        // Through the collapse the lit cells fall in: their spread shrinks frame by frame.
        let spread = |opening: &Opening| -> usize {
            let rows = opening.text();
            let left = rows.iter().filter_map(|row| row.find(|c: char| c != ' ')).min().unwrap_or(90);
            let right = rows.iter().map(|row| row.trim_end().chars().count()).max().unwrap_or(0);
            right.saturating_sub(left)
        };
        let mut previous = spread(&opening);
        for _ in 0..COLLAPSE_FRAMES - 1 {
            opening.step();
            let now = spread(&opening);
            assert!(now <= previous + 2, "the cloud only falls in: {previous} then {now}");
            previous = now;
        }
        assert!(previous < 10, "and it ends a point, in the star's cell: {previous} columns wide");
        let mut landed = false;
        for _ in 0..LAND_FRAMES {
            opening.step();
            if opening.text()[1].starts_with('\u{273b}') { landed = true; }
        }
        assert!(landed, "then the star lands in that cell: {:?}", opening.text()[1]);
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
