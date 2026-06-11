//============================================================================
//  Arcade: Data East DECO 16-bit (Caveman Ninja / Joe & Mac)
//
//  MiSTer-devel `emu` wrapper around the JOTEGO jtframe `cninja` core.
//  Clean rebuild on a pristine Template_MiSTer, vendoring inspired by the
//  working Arcade-BoogieWings_MiSTer core. Hosts jtframe's GENERATED game
//  wrapper (jtcninja_game_sdram) + jtframe's SDRAM glue (jtframe_board_sdram),
//  with pixel cens from jtframe_pxlcen and SDRAM_CLK = clk48sh (jtframe's
//  exact, proven config for this core).
//
//  GPLv3 — see rtl/cninja/jtcninja_game.v header.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS  = 'Z;
// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: USER_PP driven by wrapper; USER_OUT driven by joydb (USER_OUT_DRIVE) below
assign USER_PP = USER_PP_DRIVE;
// [MiSTer-DB9 END]
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1       = 0;
assign VGA_SCALER   = 0;
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE  = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 2'd0;   // core output is mono (L==R)

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////  ASPECT RATIO  ////////////////////////////////
// cninja is a horizontal 4:3 game (256x240).
wire [1:0] ar = status[14:13];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

//////////////////////////////   CONF_STR   //////////////////////////////////
`include "build_id.v"
localparam CONF_STR = {
	"Arcade-Deco16;;",
	"-;",
	"O[14:13],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[6],Debug pattern,Off,On;",
	"O[7],SDRAM dump (BA3),Off,On;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// [MiSTer-DB9-Pro BEGIN] - Saturn-first joy_type (canonical bit notation)
	"O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"O[125],UserIO Players, 1 Player,2 Players;",
	// [MiSTer-DB9-Pro END]
	"J1,Attack,Jump,Start,Coin,Pause;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

//////////////////////////////   CLOCKS   ////////////////////////////////////
// jtframe game PLL (vendored sys/pll): clk48 / clk48sh / clk24 / clk96.
wire clk48, clk48sh, clk24, clk96, clk96sh;
wire pll_locked;

pll pll
(
	.refclk   ( CLK_50M    ),
	.rst      ( 1'b0       ),
	.locked   ( pll_locked ),
	.outclk_0 ( clk48      ),
	.outclk_1 ( clk48sh    ),
	.outclk_2 ( clk24      ),
	.outclk_3 (            ),
	.outclk_4 ( clk96      ),
	.outclk_5 ( clk96sh    )
);

wire clk_sys = clk48;       // clk_sys == clk_rom == SDRAM clock domain

// SDRAM_CLK: jtframe's exact config for cninja (180SHIFT=0) — the PLL's
// phase-shifted 48 MHz output drives the SDRAM clock pin directly. Constrained
// as a generated clock in jtframe_sdram.sdc.
assign SDRAM_CLK = clk48sh;

//////////////////////////////   HPS IO   ////////////////////////////////////
wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;
wire  [10:0] ps2_key;

wire  [31:0] joystick_2, joystick_3;
// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: rename USB joystick wires (P1/P2 get DB9 merge)
wire  [31:0] joystick_0_USB, joystick_1_USB;
// [MiSTer-DB9 END]

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;
wire         ioctl_wait;

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper
wire         CLK_JOY = CLK_50M;                 // Assign clock between 40-50Mhz
wire   [1:0] joy_type_raw    = status[127:126]; // 0=Off, 1=Saturn, 2=DB9MD, 3=DB15
wire         joy_2p          = status[125];
// SNAC cores: replace 1'b0 with the core's SNAC enable expression so SNAC
// preempts the joydb wrapper on shared USER_IO pins. Default 1'b0 is no-op.
wire         snac_active     = 1'b0;
// MT32-pi cores on primary USER_IO: replace 1'b0 with the core's MT32-active
// expression. Deco16 has no MT32 -> stays 1'b0.
wire         mt32_primary_active = 1'b0;
wire   [1:0] joy_type        = snac_active ? 2'd0 : joy_type_raw;
wire         joy_db9md_en    = (joy_type == 2'd2);
wire         joy_db15_en     = (joy_type == 2'd3);
wire         joy_any_en      = |joy_type;
// [MiSTer-DB9 END]

// [MiSTer-DB9-Pro BEGIN] - Saturn key gate
wire         saturn_unlocked;                   // driven by hps_io UIO_DB9_KEY (0xFE)
// [MiSTer-DB9-Pro END]

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper wires + instance
wire   [7:0] USER_OUT_DRIVE;
wire   [7:0] USER_PP_DRIVE;
wire  [15:0] joydb_1, joydb_2;
wire         joydb_1ena, joydb_2ena;
wire  [15:0] joy_raw_payload;

// [MiSTer-DB9 BEGIN] - DB9 programmable-remap matrix wires
wire  [15:0] joydb_1_mapped, joydb_2_mapped;
wire         db9_remap_cmd;
wire   [5:0] db9_remap_byte_cnt;
wire  [15:0] db9_remap_din;
// [MiSTer-DB9 END]
joydb joydb (
  .clk             ( CLK_JOY         ),
  .clk_sys         ( clk_sys            ),
  .USER_IN         ( USER_IN         ),
  .OSD_STATUS          ( OSD_STATUS          ),
  .snac_active         ( snac_active         ),
  .mt32_primary_active ( mt32_primary_active ),
  .joy_type        ( joy_type        ),
  .joy_2p          ( joy_2p          ),
  .saturn_unlocked ( saturn_unlocked ),
  .USER_OUT_DRIVE  ( USER_OUT_DRIVE  ),
  .USER_PP_DRIVE   ( USER_PP_DRIVE   ),
  .USER_OSD        ( USER_OSD        ),
  .joydb_1         ( joydb_1         ),
  .joydb_2         ( joydb_2         ),
  .joydb_1ena      ( joydb_1ena      ),
  .joydb_2ena      ( joydb_2ena      ),
  .remap_cmd       ( db9_remap_cmd      ),
  .remap_byte_cnt  ( db9_remap_byte_cnt ),
  .remap_din       ( db9_remap_din      ),
  .joydb_1_mapped  ( joydb_1_mapped     ),
  .joydb_2_mapped  ( joydb_2_mapped     ),
  .joy_raw         ( joy_raw_payload )
);

assign USER_OUT = USER_OUT_DRIVE;
// [MiSTer-DB9 END]

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys            ( clk_sys            ),
	.HPS_BUS            ( HPS_BUS            ),
	.EXT_BUS            (                    ),

	.buttons            ( buttons            ),
	.status             ( status             ),
	.status_menumask    ( 16'd0              ),
	.forced_scandoubler ( forced_scandoubler ),
	.direct_video       ( direct_video       ),
	.gamma_bus          ( gamma_bus          ),

	.joystick_0         ( joystick_0_USB     ),
	.joystick_1         ( joystick_1_USB     ),
	.joystick_2         ( joystick_2         ),
	.joystick_3         ( joystick_3         ),

	.ioctl_download     ( ioctl_download     ),
	.ioctl_wr           ( ioctl_wr           ),
	.ioctl_addr         ( ioctl_addr         ),
	.ioctl_dout         ( ioctl_dout         ),
	.ioctl_index        ( ioctl_index        ),
	.ioctl_wait         ( ioctl_wait         ),

	.ps2_key            ( ps2_key            ),
	// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joy_raw + remap selector stream
	.joy_raw            ( OSD_STATUS ? joy_raw_payload : 16'b0 ),
	.db9_remap_cmd      ( db9_remap_cmd      ),
	.db9_remap_byte_cnt ( db9_remap_byte_cnt ),
	.db9_remap_din      ( db9_remap_din      ),
	// [MiSTer-DB9 END]
	// [MiSTer-DB9-Pro BEGIN] - Saturn key gate
	.saturn_unlocked    ( saturn_unlocked    )
	// [MiSTer-DB9-Pro END]
);

// [MiSTer-DB9-Pro BEGIN] - DB controllers muted while OSD is open; consume remap matrix (Layer B)
// J1 order: [3:0]=dirs, 4=Attack, 5=Jump, 6=Start, 7=Coin, 8=Pause
wire [31:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 32'd0 : {16'd0, joydb_1_mapped}) : joystick_0_USB;
wire [31:0] joystick_1 = joydb_2ena ? (OSD_STATUS ? 32'd0 : {16'd0, joydb_2_mapped}) : joydb_1ena ? joystick_0_USB : joystick_1_USB;
// [MiSTer-DB9-Pro END]

//////////////////////////////   RESET   /////////////////////////////////////
wire sdram_init;                       // from board_sdram (high while SDRAM trains)
wire dwnld_busy;                       // from game_sdram (ROM download in progress)

// SDRAM controller reset: hard reset / PLL-loss ONLY. It must run its init
// sequence and service the ROM download, so it must NOT be gated on sdram_init
// (its own output -> deadlock) or dwnld_busy.
wire rst_sd;
sync_rst u_rst_sd(.clk(clk48), .arst(RESET | ~pll_locked), .rst(rst_sd));

// Game reset: also held through SDRAM init, the ROM download and soft reset.
wire core_reset = RESET | status[0] | buttons[1] | ~pll_locked | sdram_init | dwnld_busy;
wire rst48, rst24, rst96;
sync_rst u_rst48(.clk(clk48), .arst(core_reset), .rst(rst48));
sync_rst u_rst24(.clk(clk24), .arst(core_reset), .rst(rst24));
sync_rst u_rst96(.clk(clk96), .arst(core_reset), .rst(rst96));

//////////////////////////////   DOWNLOAD   //////////////////////////////////
// MRA index 0 -> main ROM stream into the jtframe download path.
// DIPs arrive on index 254 (4 bytes).
wire        ioctl_rom = ioctl_download & (ioctl_index[15:0]==16'd0);

reg  [7:0]  dsw[0:3];
always @(posedge clk48) begin
	if (ioctl_wr && ioctl_index[15:0]==16'd254 && !ioctl_addr[24:2])
		dsw[ioctl_addr[1:0]] <= ioctl_dout;
end
wire [31:0] dipsw = {dsw[3], dsw[2], dsw[1], dsw[0]};

// Throttle the HPS while an SDRAM prog write is outstanding. prog_we is held
// from byte-latch until sdram_ack, and is 0 for BRAM(prom)/non-SDRAM bytes.
wire prog_we, prog_ack;
assign ioctl_wait = prog_we;

//////////////////////////////   INPUTS   ////////////////////////////////////
// jtframe cabinet inputs are ACTIVE-LOW (idle=1). MiSTer joystick bits are
// active-high; invert. jtframe joystick: [5:4]={B2,B1}, [3:0] dir nibble with
// JTFRAME_JOY_RLDU => {R,L,D,U} = {in[0],in[1],in[2],in[3]}.
function [5:0] jtjoy(input [31:0] m);
	jtjoy = ~{ m[5], m[4], m[0], m[1], m[2], m[3] };
endfunction

wire [5:0] joystick1 = jtjoy(joystick_0);
wire [5:0] joystick2 = jtjoy(joystick_1);
wire [5:0] joystick3 = jtjoy(joystick_2);
wire [5:0] joystick4 = jtjoy(joystick_3);

wire [3:0] cab_1p = ~{ joystick_3[6], joystick_2[6], joystick_1[6], joystick_0[6] };
wire [3:0] coin   = ~{ joystick_3[7], joystick_2[7], joystick_1[7], joystick_0[7] };
wire       game_pause = joystick_0[8] | joystick_1[8];

//////////////////////////////   GAME CORE   /////////////////////////////////
wire [7:0] red, green, blue;
wire       LHBL, LVBL, HS, VS;        // jtframe blanks are ACTIVE-LOW
wire       pxl_cen, pxl2_cen;
wire       dip_flip;

wire signed [15:0] snd;
wire         [5:0] snd_vu;
wire               snd_peak, sample;

// Board-facing SDRAM bus (muxed between the game and the debug dump engine).
wire [21:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire  [3:0] ba_rd, ba_wr;
wire  [3:0] ba_dst, ba_dok, ba_rdy, ba_ack;
// Game-side SDRAM bus (before the debug mux).
wire [21:0] g_ba0_addr, g_ba1_addr, g_ba2_addr, g_ba3_addr;
wire  [3:0] g_ba_rd, g_ba_wr;
wire [15:0] ba0_din, ba1_din, ba2_din, ba3_din;
wire  [1:0] ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [15:0] data_read;
wire [15:0] prog_data;
wire  [1:0] prog_ba, prog_mask;
wire [21:0] prog_addr;
wire        prog_rd, prog_rdy, prog_dst, prog_dok;

jtframe_pxlcen u_pxlcen(
	.clk      ( clk48    ),
	.pxl_cen  ( pxl_cen  ),
	.pxl2_cen ( pxl2_cen )
);

jtcninja_game_sdram u_game
(
	.rst        ( rst48     ),
	.clk        ( clk48     ),
	.rst24      ( rst24     ),
	.clk24      ( clk24     ),
	.rst96      ( rst96     ),
	.clk96      ( clk96     ),

	.pxl2_cen   ( pxl2_cen  ),
	.pxl_cen    ( pxl_cen   ),
	.red        ( red       ),
	.green      ( green     ),
	.blue       ( blue      ),
	.LHBL       ( LHBL      ),
	.LVBL       ( LVBL      ),
	.HS         ( HS        ),
	.VS         ( VS        ),

	.cab_1p     ( cab_1p    ),
	.coin       ( coin      ),
	.joystick1  ( joystick1 ),
	.joystick2  ( joystick2 ),
	.joystick3  ( joystick3 ),
	.joystick4  ( joystick4 ),
	.dial_x     ( 2'd0      ),
	.dial_y     ( 2'd0      ),
	.joyana_l1  ( 16'd0 ), .joyana_l2 ( 16'd0 ), .joyana_l3 ( 16'd0 ), .joyana_l4 ( 16'd0 ),
	.joyana_r1  ( 16'd0 ), .joyana_r2 ( 16'd0 ), .joyana_r3 ( 16'd0 ), .joyana_r4 ( 16'd0 ),

	.snd_en     ( 6'h3f     ),
	.snd_vol    ( 8'hff     ),

	.status     ( status[31:0] ),
	.dipsw      ( dipsw     ),
	.dip_pause  ( game_pause ? 1'b0 : 1'b1 ),
	.dip_test   ( 1'b1      ),
	.service    ( 1'b1      ),
	.tilt       ( 1'b1      ),
	.dip_flip   ( dip_flip  ),
	.dip_fxlevel( 2'b11     ),

	.st_addr    ( 8'd0      ),
	.st_dout    (           ),
	.gfx_en     ( 4'hf      ),
	.debug_bus  ( 8'd0      ),
	.debug_view (           ),

	.ioctl_addr ( ioctl_addr[25:0] ),
	.ioctl_dout ( ioctl_dout ),
	.ioctl_wr   ( ioctl_wr  ),
	.ioctl_rom  ( ioctl_rom ),
	.ioctl_ram  ( 1'b0      ),
	.ioctl_cart ( 1'b0      ),
	.dwnld_busy ( dwnld_busy ),
	.data_read  ( data_read ),

	.ba0_addr ( g_ba0_addr ), .ba1_addr ( g_ba1_addr ), .ba2_addr ( g_ba2_addr ), .ba3_addr ( g_ba3_addr ),
	.ba_rd    ( g_ba_rd    ), .ba_wr    ( g_ba_wr    ),
	.ba_dst   ( ba_dst   ), .ba_dok   ( ba_dok   ), .ba_rdy ( ba_rdy ), .ba_ack ( ba_ack ),
	.ba0_din  ( ba0_din  ), .ba1_din  ( ba1_din  ), .ba2_din ( ba2_din ), .ba3_din ( ba3_din ),
	.ba0_dsn  ( ba0_dsn  ), .ba1_dsn  ( ba1_dsn  ), .ba2_dsn ( ba2_dsn ), .ba3_dsn ( ba3_dsn ),

	.prog_data ( prog_data ),
	.prog_rdy  ( prog_rdy  ),
	.prog_ack  ( prog_ack  ),
	.prog_dst  ( prog_dst  ),
	.prog_dok  ( prog_dok  ),
	.prog_ba   ( prog_ba   ),
	.prog_we   ( prog_we   ),
	.prog_rd   ( prog_rd   ),
	.prog_mask ( prog_mask ),
	.prog_addr ( prog_addr ),

	.snd        ( snd      ),
	.snd_vu     ( snd_vu   ),
	.snd_peak   ( snd_peak ),
	.sample     ( sample   )
);

//////////////////////////////   SDRAM DUMP (debug)   /////////////////////////
// OSD "SDRAM dump" (status[7]): paint BA3's raw bytes to the screen as grayscale
// to verify the gfx ROM actually landed in SDRAM. The game keeps running so its
// video timing/raster stays alive, but this engine steals the SDRAM read bus and
// walks BA3 from address 0 (= char ROM). Structured graphics on screen => the ROM
// is really in SDRAM (the bug is downstream); noise/flat => the download wrote
// garbage and every clock/burst experiment was beside the point.
wire dbg_sdram = status[7];

reg  [8:0] dmp_h, dmp_v;
reg        dmp_hsd;
always @(posedge clk48) begin
	dmp_hsd <= HS;
	if (pxl_cen)       dmp_h <= LHBL ? dmp_h + 9'd1 : 9'd0;
	if (HS & ~dmp_hsd) dmp_v <= LVBL ? dmp_v + 9'd1 : 9'd0;
end

// 128 words (256 bytes) per scanline, base 0 = start of BA3. Two pixels per word.
wire [21:0] dmp_waddr = ({14'd0, dmp_v[7:0]} << 7) + {15'd0, dmp_h[7:1]};
reg  [21:0] dmp_addr;
reg         dmp_rd, dmp_pend;
reg  [15:0] dmp_word;
always @(posedge clk48) begin
	if (pxl_cen && dmp_h[0]==1'b0) begin   // one read per word, on the even pixel
		dmp_addr <= dmp_waddr;
		dmp_rd   <= 1'b1;
		dmp_pend <= 1'b1;
	end
	if (dmp_rd   && ba_ack[3]) dmp_rd   <= 1'b0;
	if (dmp_pend && ba_rdy[3]) begin dmp_word <= data_read; dmp_pend <= 1'b0; end
end
wire [7:0]  dmp_byte = dmp_h[0] ? dmp_word[7:0] : dmp_word[15:8];
wire [23:0] dmp_rgb  = {dmp_byte, dmp_byte, dmp_byte};

// Debug mux on the board-facing SDRAM bus (game runs but its reads are dropped).
assign ba0_addr = dbg_sdram ? 22'd0           : g_ba0_addr;
assign ba1_addr = dbg_sdram ? 22'd0           : g_ba1_addr;
assign ba2_addr = dbg_sdram ? 22'd0           : g_ba2_addr;
assign ba3_addr = dbg_sdram ? dmp_addr        : g_ba3_addr;
assign ba_rd    = dbg_sdram ? {dmp_rd, 3'b000}: g_ba_rd;
assign ba_wr    = dbg_sdram ? 4'd0            : g_ba_wr;

//////////////////////////////   SDRAM   /////////////////////////////////////
jtframe_board_sdram #(.SDRAMW(22), .MISTER(1)) u_sdram
(
	.rst        ( rst_sd     ),
	.clk        ( clk48      ),
	.init       ( sdram_init ),
	.prog_en    ( dwnld_busy ),

	.ba0_addr   ( ba0_addr   ),
	.ba1_addr   ( ba1_addr   ),
	.ba2_addr   ( ba2_addr   ),
	.ba3_addr   ( ba3_addr   ),
	.burst_addr ( 22'd0      ),
	.burst_ba   ( 2'd0       ),
	.burst_rd   ( 1'b0       ),
	.burst_wr   ( 1'b0       ),
	.ba_rd      ( ba_rd      ),
	.ba_wr      ( ba_wr      ),
	.ba0_din    ( ba0_din    ), .ba0_dsn ( ba0_dsn ),
	.ba1_din    ( ba1_din    ), .ba1_dsn ( ba1_dsn ),
	.ba2_din    ( ba2_din    ), .ba2_dsn ( ba2_dsn ),
	.ba3_din    ( ba3_din    ), .ba3_dsn ( ba3_dsn ),
	.burst_din  ( 16'd0      ),
	.burst_ack  (            ),
	.burst_rdy  (            ),
	.burst_dst  (            ),
	.burst_dok  (            ),
	.ba_ack     ( ba_ack     ),
	.ba_rdy     ( ba_rdy     ),
	.ba_dst     ( ba_dst     ),
	.ba_dok     ( ba_dok     ),
	.dout       ( data_read  ),

	.prog_addr  ( prog_addr  ),
	.prog_data  ( prog_data  ),
	.prog_dsn   ( prog_mask  ),
	.prog_ba    ( prog_ba    ),
	.prog_we    ( prog_we    ),
	.prog_rd    ( prog_rd    ),
	.prog_dok   ( prog_dok   ),
	.prog_rdy   ( prog_rdy   ),
	.prog_dst   ( prog_dst   ),
	.prog_ack   ( prog_ack   ),

	.sdram_dq   ( SDRAM_DQ   ),
	.sdram_a    ( SDRAM_A    ),
	.sdram_dqml ( SDRAM_DQML ),
	.sdram_dqmh ( SDRAM_DQMH ),
	.sdram_nwe  ( SDRAM_nWE  ),
	.sdram_ncas ( SDRAM_nCAS ),
	.sdram_nras ( SDRAM_nRAS ),
	.sdram_ncs  ( SDRAM_nCS  ),
	.sdram_ba   ( SDRAM_BA   ),
	.sdram_cke  ( SDRAM_CKE  )
);

//////////////////////////////   VIDEO   /////////////////////////////////////
// Debug test pattern (OSD "Debug pattern"): a position gradient independent of
// the game + SDRAM, for isolating video-path vs game/SDRAM faults.
reg  [8:0] tp_h, tp_v;
reg        hs_d;
always @(posedge clk48) begin
	hs_d <= HS;
	if (pxl_cen)      tp_h <= LHBL ? tp_h + 9'd1 : 9'd0;
	if (HS & ~hs_d)   tp_v <= LVBL ? tp_v + 9'd1 : 9'd0;
end
wire [23:0] testpat  = { tp_h[7:0], tp_v[7:0], tp_h[7:0] ^ tp_v[7:0] };
wire [23:0] game_rgb = dbg_sdram ? dmp_rgb : (status[6] ? testpat : { red, green, blue });

// jtframe LHBL/LVBL are active-low; arcade_video wants active-high HBlank/VBlank.
arcade_video #(.WIDTH(256), .DW(24)) u_arcade_video
(
	.clk_video          ( clk48           ),
	.ce_pix             ( pxl_cen         ),

	.RGB_in             ( game_rgb        ),
	.HBlank             ( ~LHBL           ),
	.VBlank             ( ~LVBL           ),
	.HSync              ( HS              ),
	.VSync              ( VS              ),

	.CLK_VIDEO          ( CLK_VIDEO       ),
	.CE_PIXEL           ( CE_PIXEL        ),
	.VGA_R              ( VGA_R           ),
	.VGA_G              ( VGA_G           ),
	.VGA_B              ( VGA_B           ),
	.VGA_HS             ( VGA_HS          ),
	.VGA_VS             ( VGA_VS          ),
	.VGA_DE             ( VGA_DE          ),
	.VGA_SL             ( VGA_SL          ),

	.fx                 ( status[5:3]     ),
	.forced_scandoubler ( forced_scandoubler ),
	.gamma_bus          ( gamma_bus       )
);

assign LED_USER = dwnld_busy;

//////////////////////////////   AUDIO   /////////////////////////////////////
assign AUDIO_L = snd;
assign AUDIO_R = snd;
assign AUDIO_S = 1'b1;   // signed samples

endmodule

//----------------------------------------------------------------------------
// Async-assert / sync-deassert active-high reset synchronizer.
//----------------------------------------------------------------------------
module sync_rst(input clk, input arst, output reg rst);
	reg r;
	always @(posedge clk or posedge arst)
		if (arst) {rst, r} <= 2'b11;
		else      {rst, r} <= {r, 1'b0};
endmodule
