/*  See jtcninja_game.v header.

    Video subsystem (v0) for Data East cninja.cpp (Joe & Mac).

    This v0 provides the boot-critical pieces:
      - jtframe_vtimer: real 256x240 @ ~58Hz timing so LVBL toggles and the
        68000 VBLANK IRQ (IPL5) actually fires (the stub held LVBL=1, which
        stalled boot).
      - VRAM read-back: palette (0x19c000), the two deco16ic playfield data
        RAMs per tilegen, and sprite RAM (0x1a4000) as real dual-port RAM so
        the CPU's read-back / RAM tests behave.

    NOT yet implemented (renders black): the deco16ic tilemap fetch + sprite
    drawing + colmix priority. Palette is xBGR_888 (2 words/colour), 2048
    colours - see doc/cninja.cpp PALETTE set_format.
*/
module jtcninja_video(
    input             rst,
    input             clk,
    input             pxl2_cen,
    input             pxl_cen,
    input      [ 3:0] gfx_en,
    output            flip,
    // Caveman Ninja Hardware family selector (0=cninja, 2=darkseal). Dark Seal's
    // tilegen data/control/rowscroll are exploded across the map (needs A[19:16]
    // to tell apart), so cpu_addr is widened to [19:1].
    input      [ 3:0] game_id,
    // CPU interface
    input      [19:1] cpu_addr,
    input      [15:0] cpu_dout,
    input      [ 1:0] cpu_dsn,
    input             cpu_rnw,
    input             pf0_cs,
    input             pf1_cs,
    output     [15:0] pf0_dout,
    output     [15:0] pf1_dout,
    input             objram_cs,
    input             obj_copy,
    output     [15:0] obj_dout,
    input             pal_cs,
    output     [15:0] pal_dout,
    // Char ROM (BA2)
    output            char_cs,
    output     [16:2] char_addr,
    input      [31:0] char_data,
    input             char_ok,
    // Tile ROM 1 (BA2)
    output            scr1_cs,
    output     [18:2] scr1_addr,
    input      [31:0] scr1_data,
    input             scr1_ok,
    // Tile ROM 2 (BA2)
    output            scr2_cs,
    output     [19:2] scr2_addr,
    input      [31:0] scr2_data,
    input             scr2_ok,
    // Tile ROM 2 second reader (BA2) - tilegen1 pf1 shares the tiles2 ROM
    output            scr3_cs,
    output     [19:2] scr3_addr,
    input      [31:0] scr3_data,
    input             scr3_ok,
    // Sprite ROM (BA3)
    output            obj_cs,
    output     [20:2] obj_addr,
    input      [31:0] obj_data,
    input             obj_ok,
    // Vertical position (for deco_irq raster/vblank in main)
    output     [ 8:0] vdump,
    // Video output
    output            HS,
    output            VS,
    output            LHBL,
    output            LVBL,
    output     [`JTFRAME_COLORW-1:0] red,
    output     [`JTFRAME_COLORW-1:0] green,
    output     [`JTFRAME_COLORW-1:0] blue
);

assign flip = 1'b0;     // TODO: from deco16ic control register

// ---- ROM buses: scr2=bg (tilegen1 pf2), scr1=mg (tilegen0 pf2),
//      char=fg (tilegen0 pf1, 8x8 text), obj=sprites (decospr) ----

// ---- timing ----
wire [8:0] hdump, vrender;
// Horizontal alignment: read the line buffers HOFFSET px ahead to compensate the
// line-buffer -> colmix -> palette -> blank pipeline. With the combinational
// blank (jtframe_blank DLY=0) the pipeline is 1px shorter, so HOFFSET=0 keeps the
// picture pixel-aligned to MAME (HOFFSET=1 + DLY=2 was the earlier registered combo).
localparam [8:0] HOFFSET = 9'd0;
wire [8:0] hdump_rd = hdump + HOFFSET;
jtframe_vtimer #(
    .VB_START ( 9'd247 ),
    .VB_END   ( 9'd7   ),
    .VCNT_END ( 9'd273 ),  // 274 lines total
    .VS_START ( 9'd254 ),
    .HB_START ( 9'd255 ),
    .HB_END   ( 9'd375 ),  // 376 pixels total
    .HS_START ( 9'd300 ),
    .HINIT    ( 9'd255 )
) u_vtimer(
    .clk      ( clk     ),
    .pxl_cen  ( pxl_cen ),
    .vdump    ( vdump   ),
    .vrender  ( vrender ),
    .vrender1 (         ),
    .H        ( hdump   ),
    .Hinit    (         ),
    .Vinit    (         ),
    .LHBL     ( LHBL    ),
    .LVBL     ( LVBL    ),
    .HS       ( HS      ),
    .VS       ( VS      )
);

// ---- CPU write strobes (byte lanes) ----
wire        wr    = ~cpu_rnw;
wire [1:0]  wmask = ~cpu_dsn;

// ---- scene-replay (NOMAIN): the video RAMs preload MAME's captured state
// from <scene>/{pal,t0p1,t0p2,t1p1,t1p2,oram}.bin (ENDIAN=1 = m68k byte order),
// so `jtsim -s <scene>` renders the scene with the CPU tied off. SIMFILE is
// empty in normal runs (CPU fills the RAMs). See ver/cninja/README.md.
`ifdef NOMAIN
localparam SF_PAL="pal.bin", SF_T0P1="t0p1.bin", SF_T0P2="t0p2.bin",
           SF_T1P1="t1p1.bin", SF_T1P2="t1p2.bin", SF_ORAM="oram.bin";
`else
localparam SF_PAL="", SF_T0P1="", SF_T0P2="", SF_T1P1="", SF_T1P2="", SF_ORAM="";
`endif

// ---- palette RAM : 0x19c000-0x19dfff, xBGR_888 (2 words/colour) ----
// Stored as raw 16-bit words; rendering will combine the word pair later.
wire [15:0] pal_vq;
jtframe_dual_ram16 #(.AW(12), .ENDIAN(1), .SIMFILE(SF_PAL)) u_pal(
    .clk0 ( clk ), .addr0( cpu_addr[12:1] ), .data0( cpu_dout ),
    .we0  ( {2{pal_cs & wr}} & wmask ), .q0( pal_dout ),
    .clk1 ( clk ), .addr1( palrd_a ), .data1( 16'd0 ), .we1( 2'b0 ), .q1( pal_vq )
);

wire dseal = game_id==4'd2;

// ---- deco16ic playfield data RAM (read-back), muxed per game_id ----
// cninja  : packed in a 64kB window, sub-decoded by A[15:13]
//           tilegen0/1 pf1 data @010, pf2 data @011, control @000, rowscroll @110/111
// darkseal: exploded across the map, sub-decoded by A[19:16]+A[13]
//   tilegen1: pf1 0x200000(A19_16=0,A13=0)  pf2 0x202000(A13=1)
//             rowscroll 0x222000(A19_16=2)  control 0x240000(A19_16=4)
//   tilegen0: pf1 0x260000(A19_16=6,A13=0)  pf2 0x262000(A13=1)
//             rowscroll 0x220000(A19_16=2)  control 0x2a0000(A19_16=a)
wire [15:0] t0p1_q, t0p2_q, t1p1_q, t1p2_q;
wire t0p1 = pf0_cs & (dseal ? (cpu_addr[19:16]==4'h6 & ~cpu_addr[13]) : (cpu_addr[15:13]==3'b010));
wire t0p2 = pf0_cs & (dseal ? (cpu_addr[19:16]==4'h6 &  cpu_addr[13]) : (cpu_addr[15:13]==3'b011));
wire t1p1 = pf1_cs & (dseal ? (cpu_addr[19:16]==4'h0 & ~cpu_addr[13]) : (cpu_addr[15:13]==3'b010));
wire t1p2 = pf1_cs & (dseal ? (cpu_addr[19:16]==4'h0 &  cpu_addr[13]) : (cpu_addr[15:13]==3'b011));

assign pf0_dout = t0p2 ? t0p2_q : t0p1_q;
assign pf1_dout = t1p2 ? t1p2_q : t1p1_q;

// Tile-RAM write address: darkseal's 64x64 tilegen0 maps are 8kB (A[12:1]);
// cninja's 64x32 maps are 4kB (A[11:1], high bit 0). AW=12 fits both - 64x32
// just uses the low half.
wire [11:0] tile_wa = dseal ? cpu_addr[12:1] : { 1'b0, cpu_addr[11:1] };
wire [11:0] t0p1_vaddr, t0p2_vaddr, t1p1_vaddr, t1p2_vaddr;
wire [15:0] t0p1_vq, t0p2_vq, t1p1_vq, t1p2_vq;
jtframe_dual_ram16 #(.AW(12), .ENDIAN(1), .SIMFILE(SF_T0P1)) u_t0p1(
    .clk0(clk), .addr0(tile_wa), .data0(cpu_dout),
    .we0({2{t0p1 & wr}} & wmask), .q0(t0p1_q),
    .clk1(clk), .addr1(t0p1_vaddr), .data1(16'd0), .we1(2'b0), .q1(t0p1_vq));
jtframe_dual_ram16 #(.AW(12), .ENDIAN(1), .SIMFILE(SF_T0P2)) u_t0p2(
    .clk0(clk), .addr0(tile_wa), .data0(cpu_dout),
    .we0({2{t0p2 & wr}} & wmask), .q0(t0p2_q),
    .clk1(clk), .addr1(t0p2_vaddr), .data1(16'd0), .we1(2'b0), .q1(t0p2_vq));
jtframe_dual_ram16 #(.AW(12), .ENDIAN(1), .SIMFILE(SF_T1P1)) u_t1p1(
    .clk0(clk), .addr0(tile_wa), .data0(cpu_dout),
    .we0({2{t1p1 & wr}} & wmask), .q0(t1p1_q),
    .clk1(clk), .addr1(t1p1_vaddr), .data1(16'd0), .we1(2'b0), .q1(t1p1_vq));
jtframe_dual_ram16 #(.AW(12), .ENDIAN(1), .SIMFILE(SF_T1P2)) u_t1p2(
    .clk0(clk), .addr0(tile_wa), .data0(cpu_dout),
    .we0({2{t1p2 & wr}} & wmask), .q0(t1p2_q),
    .clk1(clk), .addr1(t1p2_vaddr), .data1(16'd0), .we1(2'b0), .q1(t1p2_vq));

// ---- sprite RAM : 0x1a4000-0x1a47ff (0x400 words). Port1 = obj-engine read.
// TODO: double-buffer on obj_copy (DMA flag); scene replay reads it directly.
wire [ 9:0] oram_vaddr;
wire [15:0] oram_vq;
jtframe_dual_ram16 #(.AW(10), .ENDIAN(1), .SIMFILE(SF_ORAM)) u_obj(
    .clk0(clk), .addr0(cpu_addr[10:1]), .data0(cpu_dout),
    .we0({2{objram_cs & wr}} & wmask), .q0(obj_dout),
    .clk1(clk), .addr1(oram_vaddr), .data1(16'd0), .we1(2'b0), .q1(oram_vq));

// ---- tilegen0 pf control registers (scroll) ----
// pf2 scrollx=ctrl[3], scrolly=ctrl[4]; ctrl[5]=control0, ctrl[6]=control1
// (pf1 in low byte, pf2 in high byte)
reg [15:0] ctrl[0:7], ctrl1[0:7];
integer ci;
initial begin
    for(ci=0;ci<8;ci=ci+1) begin ctrl[ci]=0; ctrl1[ci]=0; end
`ifdef NOMAIN
    // Scene replay has no CPU to write the deco16ic control regs, so preload the
    // captured per-scene scroll/mode/bank from ctrl0.hex (tilegen0) + ctrl1.hex
    // (tilegen1), produced by rest2bin.sh.  Gives correct layer scroll positions.
    $readmemh("ctrl0.hex", ctrl);
    $readmemh("ctrl1.hex", ctrl1);
`endif
end
wire ctrl_cs  = pf0_cs & (dseal ? (cpu_addr[19:16]==4'ha)   // darkseal t0 ctrl 0x2a0000
                                : (cpu_addr[15:13]==3'b000));// cninja   t0 ctrl 0x14000x
wire ctrl1_cs = pf1_cs & (dseal ? (cpu_addr[19:16]==4'h4)   // darkseal t1 ctrl 0x240000
                                : (cpu_addr[15:13]==3'b000));// cninja   t1 ctrl 0x15000x
always @(posedge clk) begin
    if( ctrl_cs  & wr & wmask[0] ) ctrl [cpu_addr[3:1]] <= cpu_dout;
    if( ctrl1_cs & wr & wmask[0] ) ctrl1[cpu_addr[3:1]] <= cpu_dout;
end

// deco16ic tilegen1 bank callback (cninja_bank_callback): the high tile bit
// (0x1000) is set when the upper nibble of the per-pf bank-control byte is 0.
// control[7] low byte -> pf1 bank, high byte -> pf2 bank.
// cninja's tilegen1 uses a runtime bank callback (cninja_bank_callback) because
// its tiles2 ROM is 1MB (13-bit codes); the high code bit comes from ctrl1[7].
// Dark Seal has NO bank callback (darkseal.cpp) - fixed banks, 12-bit codes into
// a 512kB tiles2 - so the high bit must be 0, else rom_addr reads past the ROM
// (the "different tiles" + gappy render).
wire pf1b_bank = dseal ? 1'b0 : ~|ctrl1[7][ 7:4];   // tilegen1 pf1 bit12
wire bg_bank   = dseal ? 1'b0 : ~|ctrl1[7][15:12];  // tilegen1 pf2 (bg) bit12

// ---- background = tilegen1 pf2 (16x16 tiles2), opaque backdrop ----
wire [7:0]  bg_pxl;
wire        bg_romcs;
wire [19:2] bg_roma;
assign scr2_cs   = bg_romcs;
assign scr2_addr = bg_roma;

jtcninja_pf #(.TILE16(1)) u_bg(   // DUMPID(2) to dump bg tile fetches
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip(flip),
    .tall(1'b0), .pswap(dseal),   // tilegen1 = 64x32 (both boards)
    .scrx(ctrl1[3]), .scry(ctrl1[4]), .bank({2'd0,bg_bank}),
    .vrender(vrender), .hdump(hdump_rd), .hs(HS),
    .ram_addr(t1p2_vaddr), .ram_data(t1p2_vq),
    .rom_cs(bg_romcs), .rom_addr(bg_roma), .rom_data(scr2_data), .rom_ok(scr2_ok),
    .pxl(bg_pxl)
);

// ---- pf1b = tilegen1 pf1 (16x16, shares tiles2 ROM), col bank 0x00 -> pal 0x200
//      a detail/foreground tilemap (palms, foliage). Transparent on pen 0. ----
wire [7:0]  pf1b_pxl;
wire        pf1b_romcs;
wire [19:2] pf1b_roma;
assign scr3_cs   = pf1b_romcs;
assign scr3_addr = pf1b_roma;

jtcninja_pf #(.TILE16(1)) u_pf1b(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip(flip),
    .tall(1'b0), .pswap(dseal),   // tilegen1 = 64x32 (both boards)
    .scrx(ctrl1[1]), .scry(ctrl1[2]), .bank({2'd0,pf1b_bank}),
    .vrender(vrender), .hdump(hdump_rd), .hs(HS),
    .ram_addr(t1p1_vaddr), .ram_data(t1p1_vq),
    .rom_cs(pf1b_romcs), .rom_addr(pf1b_roma), .rom_data(scr3_data), .rom_ok(scr3_ok),
    .pxl(pf1b_pxl)
);

// ---- midground = tilegen0 pf2 (16x16 tiles1), transparent on pen 0 ----
wire [7:0]  mg_pxl;
wire        mg_romcs;
wire [19:2] mg_roma;
assign scr1_cs   = mg_romcs;
assign scr1_addr = mg_roma[18:2];   // tiles1 512kB; tilegen0 has no bank cb (bit19=0)

jtcninja_pf #(.TILE16(1)) u_mg(   // DUMPID(3) to dump mg tile fetches
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip(flip),
    .tall(dseal), .pswap(dseal),  // tilegen0 = 64x64 on darkseal, 64x32 on cninja
    .scrx(ctrl[3]), .scry(ctrl[4]), .bank(3'd0),
    .vrender(vrender), .hdump(hdump_rd), .hs(HS),
    .ram_addr(t0p2_vaddr), .ram_data(t0p2_vq),
    .rom_cs(mg_romcs), .rom_addr(mg_roma), .rom_data(scr1_data), .rom_ok(scr1_ok),
    .pxl(mg_pxl)
);

// ---- foreground = tilegen0 pf1 (8x8 chars), transparent on pen 0 ----
wire [7:0]  fg_pxl;
wire        fg_romcs;
wire [19:2] fg_roma;
assign char_cs   = fg_romcs;
assign char_addr = fg_roma[16:2];   // chars 128kB (8x8)

jtcninja_pf #(.TILE16(0)) u_fg(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip(flip),
    .tall(dseal), .pswap(dseal),  // tilegen0 = 64x64 on darkseal, 64x32 on cninja
    .scrx(ctrl[1]), .scry(ctrl[2]), .bank(3'd0),
    .vrender(vrender), .hdump(hdump_rd), .hs(HS),
    .ram_addr(t0p1_vaddr), .ram_data(t0p1_vq),
    .rom_cs(fg_romcs), .rom_addr(fg_roma), .rom_data(char_data), .rom_ok(char_ok),
    .pxl(fg_pxl)
);

// ---- sprites = decospr (MXC-06). Pen = 0x300 + colour*16 + pixel. ----
wire [10:0] obj_pxl;   // {pri[1:0], colour[4:0], pixel[3:0]}
jtcninja_obj u_obj_eng(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip(flip),
    .HS(HS), .LHBL(LHBL), .LVBL(LVBL), .vrender(vrender), .hdump(hdump_rd),
    .oram_addr(oram_vaddr), .oram_dout(oram_vq),
    .rom_cs(obj_cs), .rom_addr(obj_addr), .rom_data(obj_data), .rom_ok(obj_ok),
    .pxl(obj_pxl)
);

// ---- colmix: composite back->front, palette (xBGR_888) -> RGB ----
// pen = gfx_palette_base + (deco_col_bank + tile_pal)*16 + colour; pen0 transparent
// for overlays. The deco16ic adds its col_bank, AND the gfxdecode adds a palette
// base per gfx region (chars/tiles1 base 0, tiles2 base 512=0x200):
//   fg  tilegen0 pf1 (chars):  0x000 + (0x00+pal)*16+c = 0x000 + pf_pxl
//   mg  tilegen0 pf2 (tiles1): 0x000 + (0x10+pal)*16+c = 0x100 + pf_pxl
//   bg  tilegen1 pf2 (tiles2): 0x200 + (0x30+pal)*16+c = 0x500 + pf_pxl  <-- +0x200 base!
// Draw order back->front: bg (opaque) < mg < fg.  (tilegen1 pf1 + sprites TODO.)
wire        mg_opaque   = mg_pxl[3:0]!=4'd0;
wire        fg_opaque   = fg_pxl[3:0]!=4'd0;
wire        pf1b_opaque = pf1b_pxl[3:0]!=4'd0;   // tilegen1 pf1 -> pal 0x200
wire        obj_opaque  = obj_pxl[3:0]!=4'd0;
wire [ 1:0] obj_pri     = obj_pxl[10:9];                 // x[15:14]
wire [10:0] obj_idx     = 11'h300 + { 2'b0, obj_pxl[8:0] }; // 0x300 + colour*16 + pixel
`ifdef DSEAL_PALTEST
wire [10:0] pal_idx   = { 3'd0, hdump_rd[7:0] };  // DIAG: show palette colours 0-255 across X
`elsif BG_ONLY
wire [10:0] pal_idx   = { 3'd5, bg_pxl };   // DIAG: bg (tilegen1 pf2) only
`elsif FG_ONLY
wire [10:0] pal_idx   = { 3'd0, fg_pxl };   // DIAG: front (tilegen0 pf1) only
`elsif MG_ONLY
wire [10:0] pal_idx   = { 3'd1, mg_pxl };   // DIAG: mg (tilegen0 pf2) only
`elsif PF1B_ONLY
wire [10:0] pal_idx   = { 3'd2, pf1b_pxl }; // DIAG: pf1b (tilegen1 pf1) only
`else
// Sprite priority (decospr pri_callback, from x[15:14]): pri0 in front of all
// tilemaps; pri1 behind mg (e.g. the dinosaur neck goes under the water layer);
// pri2/3 behind mg+pf1b.  Front->back: fg > obj0 > mg > obj1 > pf1b > obj23 > bg.
wire obj_f = obj_opaque & (obj_pri==2'd0);
wire obj_m = obj_opaque & (obj_pri==2'd1);
wire obj_b = obj_opaque & (obj_pri[1]);          // pri 2 or 3
wire bg_opaque = bg_pxl[3:0]!=4'd0;
// cninja colmix (unchanged)
wire [10:0] cn_pal_idx = fg_opaque   ? { 3'd0, fg_pxl   } :
                         obj_f       ? obj_idx            :
                         mg_opaque   ? { 3'd1, mg_pxl   } :
                         obj_m       ? obj_idx            :
                         pf1b_opaque ? { 3'd2, pf1b_pxl } :
                         obj_b       ? obj_idx            :
                                       { 3'd5, bg_pxl   };
// Dark Seal colmix (darkseal.cpp screen_update). gfxdecode bases: chars 0x000,
// sprites 0x100, tiles1 0x300, tiles2 0x400. Draw order back->front:
//   tilegen1 pf1 (pf1b) < tilegen1 pf2 (bg) < tilegen0 pf1 (fg/chars) < sprites
//   < tilegen0 pf2 (mg/tiles1, FRONT). Backdrop = black_pen (palette 0).
wire [10:0] ds_pal_idx = mg_opaque   ? { 3'd3, mg_pxl   } :          // tiles1, front
                         obj_opaque  ? 11'h100 + {2'b0, obj_pxl[8:0]} :  // sprites
                         fg_opaque   ? { 3'd0, fg_pxl   } :          // chars
                         bg_opaque   ? { 3'd4, bg_pxl   } :          // tiles2 (tilegen1 pf2)
                         pf1b_opaque ? { 3'd4, pf1b_pxl } :          // tiles2 (tilegen1 pf1)
                                       11'd0;                        // black backdrop
wire [10:0] pal_idx = dseal ? ds_pal_idx : cn_pal_idx;
`endif
// xBGR_888, 2 words/colour. Even word(@+0)={x,B}, odd word(@+2)={G,R}; the 68000
// stores the 32-bit xBGR long big-endian. Verified vs MAME screen pixels:
//   R = odd[7:0], G = odd[15:8], B = even[7:0].  (jtframe_dual_ram16 q1 has 1-cyc
//   latency, so phase=0 captures the even word, phase=1 the odd word.)
// Palette read, muxed per game_id. Both are 24-bit (xBGR_888) but stored
// differently: cninja interleaves 2 words/colour (even={x,B}, odd={G,R}) in one
// region; darkseal splits the same RAM in half - GR {G,R} in the low 2048
// (0x140000), B {x,B} in the high 2048 (0x141000). Either way the final
// {gr_w[15:8],gr_w[7:0],xb_w[7:0]} = {G,R,B} assembly is identical.
reg  [11:0] palrd_a;
reg         phase;
reg  [15:0] xb_w, gr_w;
always @(posedge clk) begin
    phase   <= ~phase;
    palrd_a <= dseal ? { phase, pal_idx } : { pal_idx, phase };
    if( dseal ) begin
        if( !phase ) gr_w <= pal_vq;      // darkseal low half  {G,R}
        else         xb_w <= pal_vq;      // darkseal high half {x,B}
    end else begin
        if( !phase ) xb_w <= pal_vq;      // cninja even word {x,B}
        else         gr_w <= pal_vq;      // cninja odd  word {G,R}
    end
end

jtframe_blank #(.DLY(0),.DW(24)) u_blank(
    .clk     ( clk     ),
    .pxl_cen ( pxl_cen ),
    .preLHBL ( LHBL    ),
    .preLVBL ( LVBL    ),
    .LHBL    (         ),
    .LVBL    (         ),
    .preLBL  (         ),
    .rgb_in  ( { gr_w[15:8], gr_w[7:0], xb_w[7:0] } ),  // {G, R, B}
    .rgb_out ( { green, red, blue } )
);

endmodule
