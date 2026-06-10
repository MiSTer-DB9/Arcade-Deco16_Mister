/*  you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    this program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this.  If not, see <http://www.gnu.org/licenses/>.

    Author: Andrea Bogazzi
    Date: 2026-06-10
*/

module jtcninja_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

// ---------------------------------------------------------------------------
// Main CPU bus
// (main_dout, dsn, main_addr, the audio channels and red/green/blue are
//  generated game ports - declared via mem_ports.inc / common_ports.inc -
//  so they are driven here, not redeclared)
// ---------------------------------------------------------------------------
wire        UDSWn, LDSWn, main_rnw;

// Tilegen (deco16ic x2) chip-select / register interface
wire        pf0_cs, pf1_cs;     // tilegen[0] / tilegen[1] register banks
wire [15:0] pf0_dout, pf1_dout;

// Sprites (decospr)
wire        objram_cs, obj_copy;
wire [15:0] obj_dout;
// Sprite gfx ROM: the engine drives one logical 32-bit bus (obj_*), fanned out
// to the two parallel 1MB banks obj1 (BA0, planes 0,1) + obj2 (BA1, planes 2,3).
wire [20:2] obj_addr;
wire        obj_cs, obj_ok;
wire [31:0] obj_data;

// DECO 16-bit data strobes (no SDRAM rw bus references this any more, so dsn is
// a plain local wire now that work RAM lives in BRAM).
wire [ 1:0] dsn;

// Palette
wire        pal_cs;
wire [15:0] pal_dout;

// Protection (DECO 104) -- the critical-path block
wire        prot_cs;
wire [15:0] prot_dout;

// Sound. cninja routes the soundlatch through the DECO 104 (prot_*); darkseal
// writes 0x180008 directly (main.v snd_wr/snd_dout). Muxed on game_id below.
wire [ 7:0] snd_latch, prot_snd_latch, ds_snd_latch;
wire        snd_irq,   prot_snd_irq;
wire        snd_wr;
wire [ 7:0] snd_dout;
reg  [ 7:0] ds_snd_latch_r;
reg         snd_wr_l;
wire        dseal = game_id==4'd2;
always @(posedge clk) begin
    snd_wr_l <= snd_wr;
    if( snd_wr ) ds_snd_latch_r <= snd_dout;
end
assign ds_snd_latch = ds_snd_latch_r;
assign snd_latch    = dseal ? ds_snd_latch : prot_snd_latch;
assign snd_irq      = dseal ? (snd_wr & ~snd_wr_l) : prot_snd_irq;

// Video vertical position (deco_irq raster/vblank lives in main)
wire [ 8:0] vdump;

// Video timing / mix
wire        flip;
wire        cen_opn, cen_opm, cen_oki1, cen_oki2;

assign dsn        = { UDSWn, LDSWn };
assign dip_flip   = flip;
assign debug_view = 8'd0;
assign st_dout    = 8'd0;

// Sprite ROM bank fan-out: same word index to both 1MB banks; recombine the two
// dw16 reads into the 32-bit word the engine expects. obj1=={pl1,pl0} (low),
// obj2=={pl3,pl2} (high) - identical layout to the old single dw32 obj read.
assign obj1_addr  = obj_addr;
assign obj2_addr  = obj_addr;
assign obj1_cs    = obj_cs;
assign obj2_cs    = obj_cs;
assign obj_data   = { obj2_data, obj1_data };
assign obj_ok     = obj1_ok & obj2_ok;


// ROM download remap (BA3 = char/tiles1/tiles2). NOTE: post_addr/prog_addr are
// 16-bit-WORD addresses (jtframe_dwnld: prog_addr=(part_addr-BA_START)>>1; the
// byte lane comes from prog_mask, so a remap can only move whole words). BA3 word
// layout:  char 0x00000-0x10000 | tiles1 0x10000-0x50000 | tiles2 0x50000-0xD0000
// The deco16ic 4bpp tiles are RGN_FRAC(1,2): planes 0,1 in the first ROM half and
// planes 2,3 in the second. Rotating each region's word offset left by 1 (moving
// the half-select MSB to the LSB) interleaves the halves so one 32-bit read packs
// {plane1,plane0} and {plane3,plane2}. tiles2 also needs the MAME ROM_CONTINUE
// de-interleave (mame2mra emits mag-00|mag-01 naive; the real region swaps the
// middle 256kB blocks = word bits 17<->18), folded into the rotate. Verified
// end-to-end against the MAME gfxdecode (0 px mismatch).
//
// Sprites are NOT remapped here: they load as ONE contiguous 2MB region at the
// blob start, and the jtframe_dwnld boundary at JTFRAME_BA1_START splits the
// RGN_FRAC(1,2) plane pairs into BA0 (planes 0,1) + BA1 (planes 2,3) for free.
// The sprite engine then reads both banks in parallel (obj1/obj2 combine below).
localparam [21:0] T1W = 22'h10000,    // tiles1 word base in BA3
                  T2W = 22'h50000,    // tiles2 word base in BA3
                  GFXEND = 22'hD0000;  // end of tiles2 / start of proms in BA3
wire [19:0] t1w = prog_addr[19:0] - 20'h10000;   // tiles1-relative word
wire [19:0] t2w = prog_addr[19:0] - 20'h50000;   // tiles2-relative word
always @* begin
    post_data = prog_data;
    post_addr = prog_addr;                                   // identity (sprites BA0/1, proms)
    // Dark Seal maincpu (BA2, first 512kB) is data-line scrambled: MAME's
    // driver_init swaps data bits D1<->D6 across the whole 68k ROM
    //   rom = (rom&0xbd) | ((rom&0x02)<<5) | ((rom&0x40)>>5)
    // Apply the same swap during download (game_id==2 only). The download is
    // byte-wide (prog_data[7:0]), so swap bits 6<->1 of each byte.
    if( dseal && prog_ba==2'd2 && prog_addr < 22'h40000 )
        post_data = { prog_data[7], prog_data[1], prog_data[5:2], prog_data[6], prog_data[0] };
    if( prog_ba==2'd3 ) begin                                // BA3 = char/tiles gfx
        if( prog_addr < T1W )                                // char  (half @ word bit15)
            post_addr = { 6'd0, prog_addr[14:0], prog_addr[15] };
        else if( prog_addr < T2W )                           // tiles1 (half @ word bit17)
            post_addr = T1W + { 4'd0, t1w[16:0], t1w[17] };
        // tiles2. cninja is 1MB [T2W,0xD0000) with ROM_CONTINUE (swap word bits
        // 17<->18). darkseal is a single 512kB ROM [T2W,0x90000) - just the
        // RGN_FRAC rotate. CRITICAL: darkseal's range MUST stop at 0x90000, not
        // GFXEND(0xD0000): the remap ignores bits >=18, so the blob padding that
        // follows darkseal's smaller tiles2 (prog_addr 0x90000+) would otherwise
        // fold onto the SAME post_addr and overwrite the real tiles2 with 0xff.
        else if( prog_addr < (dseal ? 22'h90000 : GFXEND) )
            post_addr = dseal ? T2W + { 4'd0, t2w[16:0], t2w[17] }
                              : T2W + { 3'd0, t2w[18], t2w[16:0], t2w[17] };
        // else: padding/proms (>= region end): identity (no remap, no overwrite)
    end
end

// ---------------------------------------------------------------------------
// Caveman Ninja Hardware family selector (multi-game, header-driven).
// MRA header byte 0 = game_id, latched during the header phase of the download
// (superman/kiwi pattern). 0=cninja, 1=cbuster/twocrude, 2=darkseal/gatedoom.
// The address decoder / I/O / clock cens mux on game_id; game_id=0 == cninja.
// ---------------------------------------------------------------------------
reg [3:0] game_id = 4'd0;
always @(posedge clk) begin
    if( prog_we && header && prog_addr[3:0]==4'd0 )
        game_id <= prog_data[3:0];
end

// Sound-domain cens from the 32.220 MHz crystal (clk = 48 MHz):
//   xtal cen = 48*537/800 = 32.22 MHz, then integer-divide per chip:
//   YM2203/H6280 /8, YM2151 /9, OKI2 /16, OKI1 /32.
wire [1:0] xtal_cen;
wire cen_xtal = xtal_cen[0];
reg  [4:0] xcnt;     // /8, /16, /32 (power-of-two)
reg  [3:0] xc9;      // /9
jtframe_frac_cen #(.WC(10)) u_sndcen(
    .clk ( clk      ), .n( 10'd537 ), .m( 10'd800 ),
    .cen ( xtal_cen ), .cenb(        )
);
always @(posedge clk, posedge rst) begin
    if( rst ) begin xcnt<=0; xc9<=0; end
    else if( cen_xtal ) begin
        xcnt <= xcnt + 5'd1;
        xc9  <= xc9==4'd8 ? 4'd0 : xc9+4'd1;
    end
end
assign cen_opn  = cen_xtal & (xcnt[2:0]==3'd0);   // 4.0275 MHz
assign cen_opm  = cen_xtal & (xc9 ==4'd0);        // 3.58   MHz
assign cen_oki2 = cen_xtal & (xcnt[3:0]==4'd0);   // 2.0138 MHz
assign cen_oki1 = cen_xtal & (xcnt[4:0]==5'd0);   // 1.0069 MHz

/* verilator tracing_off */
jtcninja_main u_main(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .LVBL       ( LVBL      ),
    .LHBL       ( LHBL      ),
    // CPU bus
    .cpu_addr   ( main_addr ),
    .cpu_dout   ( main_dout ),
    .UDSWn      ( UDSWn     ),
    .LDSWn      ( LDSWn     ),
    .RnW        ( main_rnw  ),
    // Program ROM (work RAM is internal BRAM, no SDRAM bus)
    .rom_cs     ( main_cs   ),
    .rom_data   ( main_data ),
    .rom_ok     ( main_ok   ),
    // Video subsystem chip-selects
    .pf0_cs     ( pf0_cs    ),
    .pf1_cs     ( pf1_cs    ),
    .pf0_dout   ( pf0_dout  ),
    .pf1_dout   ( pf1_dout  ),
    .objram_cs  ( objram_cs ),
    .obj_copy   ( obj_copy  ),
    .obj_dout   ( obj_dout  ),
    .pal_cs     ( pal_cs    ),
    .pal_dout   ( pal_dout  ),
    // Protection (DECO 104) - reads inputs/dips, carries the sound latch
    .prot_cs    ( prot_cs   ),
    .prot_dout  ( prot_dout ),
    // Caveman Ninja Hardware family selector + Dark Seal direct I/O
    .game_id    ( game_id   ),
    .snd_wr     ( snd_wr    ),
    .snd_dout   ( snd_dout  ),
    .joystick1  ( joystick1 ),
    .joystick2  ( joystick2 ),
    .cab_1p     ( cab_1p    ),
    .coin       ( coin      ),
    .dipsw      ( dipsw[15:0] ),
    // misc
    .vdump      ( vdump     ),
    .dip_pause  ( dip_pause )
);

/* verilator tracing_off */
jtcninja_deco104 u_prot(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .LVBL       ( LVBL      ),
    .cs         ( prot_cs   ),
    .addr       ( main_addr[13:1] ),   // offset within the 0x4000 prot region
    .din        ( main_dout ),
    .dout       ( prot_dout ),
    .rnw        ( main_rnw  ),
    .dsn        ( dsn       ),
    // Cabinet inputs (muxed/scrambled by the chip)
    .joystick1  ( joystick1 ),
    .joystick2  ( joystick2 ),
    .cab_1p     ( cab_1p    ),
    .coin       ( coin      ),
    .service    ( service   ),
    .dip_test   ( dip_test  ),
    .dipsw      ( dipsw[15:0] ),
    // Sound (cninja path; muxed against the darkseal direct latch above)
    .snd_latch  ( prot_snd_latch ),
    .snd_irq    ( prot_snd_irq   )
);

/* verilator tracing_on */
jtcninja_snd u_snd(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen_opn    ( cen_opn   ),
    .cen_opm    ( cen_opm   ),
    .cen_oki1   ( cen_oki1  ),
    .cen_oki2   ( cen_oki2  ),
    // From main CPU (via DECO 104 latch)
    .latch      ( snd_latch ),
    .snd_irq    ( snd_irq   ),
    // Program ROM (64kB HuC6280 program in BRAM, not SDRAM): always ready,
    // no chip-select needed. snd_addr/snd_data are the generated BRAM ports.
    .rom_addr   ( snd_addr  ),
    .rom_cs     (           ),
    .rom_data   ( snd_data  ),
    .rom_ok     ( 1'b1      ),
    // OKI #1
    .oki1_addr  ( oki1_addr ),
    .oki1_cs    ( oki1_cs   ),
    .oki1_data  ( oki1_data ),
    .oki1_ok    ( oki1_ok   ),
    // OKI #2
    .oki2_addr  ( oki2_addr ),
    .oki2_cs    ( oki2_cs   ),
    .oki2_data  ( oki2_data ),
    .oki2_ok    ( oki2_ok   ),
    // Mixed channels (YM2151 is stereo: opm_l/opm_r)
    .opn        ( opn       ),
    .psg        ( psg       ),
    .opm_l      ( opm_l     ),
    .opm_r      ( opm_r     ),
    .pcm1       ( pcm1      ),
    .pcm2       ( pcm2      )
);

/* verilator tracing_off */
jtcninja_video u_video(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl2_cen   ( pxl2_cen  ),
    .pxl_cen    ( pxl_cen   ),
    .gfx_en     ( gfx_en    ),
    .flip       ( flip      ),
    .game_id    ( game_id   ),
    // CPU interface (widened to [19:1] so video can decode darkseal's exploded
    // tilegen/palette regions; cninja only needs [15:1])
    .cpu_addr   ( main_addr[19:1] ),
    .cpu_dout   ( main_dout ),
    .cpu_dsn    ( dsn       ),
    .cpu_rnw    ( main_rnw  ),
    .pf0_cs     ( pf0_cs    ),
    .pf1_cs     ( pf1_cs    ),
    .pf0_dout   ( pf0_dout  ),
    .pf1_dout   ( pf1_dout  ),
    .objram_cs  ( objram_cs ),
    .obj_copy   ( obj_copy  ),
    .obj_dout   ( obj_dout  ),
    .pal_cs     ( pal_cs    ),
    .pal_dout   ( pal_dout  ),
    // Tile ROMs (BA2)
    .char_cs    ( char_cs   ),
    .char_addr  ( char_addr ),
    .char_data  ( char_data ),
    .char_ok    ( char_ok   ),
    .scr1_cs    ( scr1_cs   ),
    .scr1_addr  ( scr1_addr ),
    .scr1_data  ( scr1_data ),
    .scr1_ok    ( scr1_ok   ),
    .scr2_cs    ( scr2_cs   ),
    .scr2_addr  ( scr2_addr ),
    .scr2_data  ( scr2_data ),
    .scr2_ok    ( scr2_ok   ),
    .scr3_cs    ( scr3_cs   ),
    .scr3_addr  ( scr3_addr ),
    .scr3_data  ( scr3_data ),
    .scr3_ok    ( scr3_ok   ),
    // Sprite ROM (BA3)
    .obj_cs     ( obj_cs    ),
    .obj_addr   ( obj_addr  ),
    .obj_data   ( obj_data  ),
    .obj_ok     ( obj_ok    ),
    // Vertical position
    .vdump      ( vdump     ),
    // Video output
    .HS         ( HS        ),
    .VS         ( VS        ),
    .LHBL       ( LHBL      ),
    .LVBL       ( LVBL      ),
    .red        ( red       ),
    .green      ( green     ),
    .blue       ( blue      )
);

endmodule
