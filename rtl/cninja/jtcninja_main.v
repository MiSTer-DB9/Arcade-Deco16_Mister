/*  See jtcninja_game.v header.

    Main 68000 subsystem for Data East cninja.cpp (Joe & Mac).
    Reference memory map: doc/cninja.cpp ::cninja_map

      000000-0bffff  program ROM
      140000-14ffff  tilegen[0] (deco16ic): control, pf1/pf2 data, rowscroll
      150000-15ffff  tilegen[1] (deco16ic)
      184000-187fff  work RAM (16kB)
      190000-190007  deco_irq (raster/vblank)        IPL: rstr1=3 rstr2=4 vbl=5
      19c000-19dfff  palette (write16)
      1a4000-1a47ff  sprite RAM
      1b4000         sprite DMA flag (write)
      1bc000-1bffff  DECO 104 protection / I/O / soundlatch

    NB inputs and dip switches are read THROUGH the DECO 104, not mapped
    directly here - they live in jtcninja_deco104.
*/
module jtcninja_main(
    input             rst,
    input             clk,
    input             LVBL,
    input             LHBL,
    // CPU bus (19-bit word address: 768kB main ROM needs A[19:1])
    output     [19:1] cpu_addr,
    output     [15:0] cpu_dout,
    output            UDSWn,
    output            LDSWn,
    output            RnW,
    // Program ROM (BA2). Work RAM (0x184000) is internal BRAM, not SDRAM.
    output            rom_cs,
    input      [15:0] rom_data,
    input             rom_ok,
    // Tilegen register banks (deco16ic x2)
    output            pf0_cs,
    output            pf1_cs,
    input      [15:0] pf0_dout,
    input      [15:0] pf1_dout,
    // Sprites
    output            objram_cs,
    output            obj_copy,
    input      [15:0] obj_dout,
    // Palette
    output            pal_cs,
    input      [15:0] pal_dout,
    // Protection (DECO 104) - also reads inputs/dips and the sound latch
    output            prot_cs,
    input      [15:0] prot_dout,
    // Caveman Ninja Hardware family selector (0=cninja, 2=darkseal)
    input      [ 3:0] game_id,
    // Direct cabinet inputs (darkseal reads these straight off the bus at
    // 0x180000-0x180004; cninja goes through the DECO 104 and ignores them)
    output            snd_wr,      // darkseal soundlatch write strobe (0x180008)
    output     [ 7:0] snd_dout,    // darkseal soundlatch data
    input      [`JTFRAME_BUTTONS+3:0] joystick1,
    input      [`JTFRAME_BUTTONS+3:0] joystick2,
    input      [ 3:0] cab_1p,
    input      [ 3:0] coin,
    input      [15:0] dipsw,
    // misc
    input      [ 8:0] vdump,      // beam position for deco_irq raster/vblank
    input             dip_pause
);
`ifndef NOMAIN
wire [23:1] A;
wire [ 2:0] FC;
reg  [ 2:0] IPLn;
wire        BGn;
wire        ASn, UDSn, LDSn, BUSn, VPAn;
reg  [15:0] cpu_din;
wire        cpu_cen, cpu_cenb;
wire        DTACKn;
reg         ok_dly;

// deco_irq (0x190000): vblank IRQ (IPL5), raster1/raster2 IRQ (IPL3/IPL4)
reg  [ 7:0] rs_line;          // raster IRQ target scanline
reg         rs_target;        // 0=raster1 (IPL3), 1=raster2 (IPL4)
reg         rs_mask;          // raster IRQ masked
reg         vbl_irq, ras_irq;
reg  [ 8:0] vdump_l;
reg  [ 2:0] warmup;
reg  [15:0] irq_dout;
wire [ 7:0] irq_status = { 1'b1, 1'b0, ras_irq, vbl_irq, 2'b00, ~LVBL, ~LHBL };

// Address decode (byte top = A[23:16] since byte addr = {A,1'b0})
wire        irq_cs, objdma_cs, ramdec;
wire [15:0] ram_q;

assign UDSWn    = RnW | UDSn;
assign LDSWn    = RnW | LDSn;
assign BUSn     = ASn | (LDSn & UDSn);
assign VPAn     = ~&{ FC, ~ASn };
assign cpu_addr = A[19:1];
// flip is owned by jtcninja_video (deco16ic control reg); not driven here.

// Work RAM (0x184000-0x187fff, 16kB) lives in BRAM, NOT SDRAM: the 68000
// must clear it during init fast enough to reach 0x47a before the first
// VBLANK, else the VBL ISR preempts init and the boot handshake stalls.
//
// Address decode is muxed for the Caveman Ninja Hardware family (game_id):
//   game_id 0 = cninja (default)         game_id 2 = darkseal
// Dark Seal's map (doc/DARKSEAL_HW.md): ROM <0x80000, work RAM 0x100000,
// objram 0x120000, palette 0x140000(RG)+0x141000(B), I/O 0x180000-0x18000b
// DIRECT (no DECO 104), tilegen[1] 0x20/0x22/0x24, tilegen[0] 0x26/0x2a.
wire ds = game_id==4'd2;

// Dark Seal direct I/O window 0x180000-0x18000f (read inputs, write control)
wire ds_io      = ds && A[23:16]==8'h18 && A[15:14]==2'b00;
wire ds_dsw_cs  = ds_io && A[3:1]==3'd0;        // 0x180000 DSW   (read)
wire ds_p1p2_cs = ds_io && A[3:1]==3'd1;        // 0x180002 P1_P2 (read)
wire ds_sys_cs  = ds_io && A[3:1]==3'd2;        // 0x180004 SYSTEM(read)
wire ds_sprdma  = ds_io && A[3:1]==3'd3 && ~RnW;// 0x180006 sprite buffer (write)
wire ds_snd_cs  = ds_io && A[3:1]==3'd4 && ~RnW;// 0x180008 soundlatch    (write)
wire ds_irqack  = ds_io && A[3:1]==3'd5 && ~RnW;// 0x18000a irq ack       (write)

assign rom_cs    = !BUSn && (ds ? A[23:16] < 8'h08 : A[23:16] < 8'h0c);
assign ramdec    = !BUSn && (ds ? (A[23:16]==8'h10 && A[15:14]==2'b00)         // 100000-103fff
                                : (A[23:16]==8'h18 && A[15:14]==2'b01));        // 184000-187fff
assign pal_cs    = !BUSn && (ds ? (A[23:16]==8'h14)                            // 140000-141fff (GR+B)
                                : (A[23:16]==8'h19 && A[15:13]==3'b110));       // 19c000-19dfff
assign objram_cs = !BUSn && (ds ? (A[23:16]==8'h12 && A[15:11]==5'd0)          // 120000-1207ff
                                : (A[23:16]==8'h1a && A[15:14]==2'b01));        // 1a4000-1a47ff
// tilegens: cninja packs each in a 64kB window; darkseal explodes data/control
// across the map. pf0_cs = tilegen[0] footprint, pf1_cs = tilegen[1] footprint.
// video.v re-decodes the sub-regions per game_id.
assign pf0_cs    = !BUSn && (ds ? (A[23:16]==8'h26 || A[23:16]==8'h2a)         // t0 data 260000 / ctrl 2a0000
                                : (A[23:16]==8'h14));
assign pf1_cs    = !BUSn && (ds ? (A[23:16]==8'h20 || A[23:16]==8'h22 || A[23:16]==8'h24) // t1 data/rowscr/ctrl
                                : (A[23:16]==8'h15));
assign irq_cs    = !BUSn && !ds && A[23:16]==8'h19 && A[15:4]==12'h0;          // cninja deco_irq
assign objdma_cs = !BUSn && !ds && A[23:16]==8'h1b && A[15:14]==2'b01;         // cninja sprite DMA
assign prot_cs   = !BUSn && !ds && A[23:16]==8'h1b && A[15:14]==2'b11;         // cninja DECO 104
assign obj_copy  = ds ? ds_sprdma : (objdma_cs & ~RnW);

// Dark Seal soundlatch (0x180008) -> sound CPU (game.v muxes this vs DECO 104)
assign snd_wr    = ds_snd_cs;
assign snd_dout  = cpu_dout[7:0];

// Dark Seal direct input words. jtframe joystick/cab/coin are ALREADY active-low
// (idle=1), matching MAME's IP_ACTIVE_LOW - so NO inversion (same as the DECO 104
// port_a). P1_P2 byte = {START, 1, B2, B1, dir[3:0]} per player (dir order vs
// MAME TBD - fine for boot). SYSTEM: [2:0]=COIN1/2/3, [3]=vblank (ACTIVE HIGH).
wire [15:0] ds_p1p2_din = { cab_1p[1], 1'b1, joystick2[`JTFRAME_BUTTONS+3:0],
                            cab_1p[0], 1'b1, joystick1[`JTFRAME_BUTTONS+3:0] };
wire [15:0] ds_sys_din  = { 8'hff, 4'b1111, ~LVBL, 1'b1, coin[1], coin[0] };

// Interrupt priority:
//   cninja  : vblank (5) > raster2 (4) > raster1 (3)   (deco_irq)
//   darkseal: vblank (6) only                          (irq6_line_assert)
always @* begin
    if( ds ) begin
        IPLn = vbl_irq ? ~3'd6 : ~3'd0;
    end else begin
        if     ( vbl_irq            ) IPLn = ~3'd5;
        else if( ras_irq & rs_target ) IPLn = ~3'd4;
        else if( ras_irq            ) IPLn = ~3'd3;
        else                          IPLn = ~3'd0;
    end
end

// deco_irq register reads (byte regs, low byte; see doc/deco_irq.cpp map)
//   offset 1 (0x190002): scanline_r   offset 2 (0x190004): raster ack (0xff)
//   offset 3 (0x190006): status_r
always @* begin
    case( A[3:1] )
        3'd1:    irq_dout = { 8'hff, rs_line     };
        3'd3:    irq_dout = { 8'hff, irq_status  };
        default: irq_dout = 16'hffff;   // raster_irq_ack_r returns 0xff
    endcase
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ok_dly    <= 0;
        vdump_l   <= 0;
        vbl_irq   <= 0;
        ras_irq   <= 0;
        rs_line   <= 0;
        rs_target <= 0;
        rs_mask   <= 1;
        warmup    <= 3'd4;
    end else begin
        ok_dly  <= rom_ok;
        vdump_l <= vdump;
        // VBLANK IRQ at the first blank line (visible bottom 247 + 1).
        // Swallow the first few vblanks after reset: the sim ROM download
        // desyncs CPU reset from the free-running vtimer, so without this the
        // first vblank can land during the masked init and preempt it.
        if( vdump==9'd248 && vdump_l!=9'd248 ) begin
            if( warmup!=3'd0 ) warmup <= warmup - 3'd1;
            else               vbl_irq <= 1;
        end
        // Raster IRQ when the beam reaches the programmed (visible) line
        if( !rs_mask && rs_line<8'd240 && vdump=={1'b0,rs_line} && vdump_l!={1'b0,rs_line} )
            ras_irq <= 1;
        // Register writes (byte data on D[7:0])
        if( irq_cs && !RnW ) case( A[3:1] )
            3'd0: begin rs_target<=cpu_dout[4]; rs_mask<=cpu_dout[1];
                        if( cpu_dout[1] ) ras_irq<=0; end   // mask acks raster
            3'd1: rs_line <= cpu_dout[7:0];
            3'd2: vbl_irq <= 0;                              // vblank_irq_ack_w
            default:;
        endcase
        // raster_irq_ack_r: reading offset 2 acks the raster IRQ
        if( irq_cs && RnW && A[3:1]==3'd2 ) ras_irq <= 0;
        // Dark Seal: write to 0x18000a acks the vblank IRQ
        if( ds_irqack ) vbl_irq <= 0;
    end
end

always @(posedge clk) begin
    cpu_din <= rom_cs     ? rom_data    :
               ramdec     ? ram_q       :
               ds_dsw_cs  ? dipsw       :   // darkseal 0x180000 DSW
               ds_p1p2_cs ? ds_p1p2_din :   // darkseal 0x180002 P1_P2
               ds_sys_cs  ? ds_sys_din  :   // darkseal 0x180004 SYSTEM
               pf0_cs     ? pf0_dout    :
               pf1_cs     ? pf1_dout    :
               pal_cs     ? pal_dout    :
               objram_cs  ? obj_dout    :
               prot_cs    ? prot_dout   :
               irq_cs     ? irq_dout    :
               16'hffff;
end

// Only the SDRAM-backed ROM read stalls the bus; work RAM is now BRAM.
wire bus_cs   = rom_cs;
wire bus_busy = rom_cs & ~ok_dly;

// Work RAM in BRAM (single-cycle, like the real SRAM)
jtframe_dual_ram16 #(.AW(13)) u_ram(
    .clk0   ( clk       ),
    .addr0  ( A[13:1]   ),
    .data0  ( cpu_dout  ),
    .we0    ( {2{ramdec & ~RnW}} & ~{UDSn,LDSn} ),
    .q0     ( ram_q     ),
    .clk1   ( clk       ),
    .addr1  ( 13'd0     ),
    .data1  ( 16'd0     ),
    .we1    ( 2'b0      ),
    .q1     (           )
);

jtframe_68kdtack_cen #(.W(8)) u_dtack(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cpu_cen    ( cpu_cen   ),
    .cpu_cenb   ( cpu_cenb  ),
    .bus_cs     ( bus_cs    ),
    .bus_busy   ( bus_busy  ),
    .bus_legit  ( 1'b0      ),
    .bus_ack    ( 1'b0      ),
    .ASn        ( ASn       ),
    .DSn        ({UDSn,LDSn}),
    .num        ( 7'd6      ),  // 24MHz/2 = 12MHz CPU (clk=48MHz, 48*6/24)
    .den        ( 8'd24     ),
    .DTACKn     ( DTACKn    ),
    .wait2      ( 1'b0      ),
    .wait3      ( 1'b0      ),
    .fave       (           ),
    .fworst     (           )
);

jtframe_m68k u_cpu(
    .clk        ( clk         ),
    .rst        ( rst         ),
    .cpu_cen    ( cpu_cen     ),
    .cpu_cenb   ( cpu_cenb    ),
    // Buses
    .eab        ( A           ),
    .iEdb       ( cpu_din     ),
    .oEdb       ( cpu_dout    ),
    .eRWn       ( RnW         ),
    .LDSn       ( LDSn        ),
    .UDSn       ( UDSn        ),
    .ASn        ( ASn         ),
    .VPAn       ( VPAn        ),
    .FC         ( FC          ),
    .BERRn      ( 1'b1        ),
    // Bus arbitration
    .RESETn     (             ),
    .HALTn      ( dip_pause   ),
    .BRn        ( 1'b1        ),
    .BGACKn     ( 1'b1        ),
    .BGn        ( BGn         ),
    .DTACKn     ( DTACKn      ),
    .IPLn       ( IPLn        )
);

`ifdef SIMULATION
// Heartbeat: per-frame liveness + cumulative palette/tilegen/sprite write
// counts (compare to MAME: full boot writes 4096 palette + ~50k tilegen).
integer frcnt = 0, palw = 0, tilew = 0, objw = 0, vbl_set = 0, irqack = 0;
reg palcs_l, tilecs_l, objcs_l, vbl_irq_l, irqack_l;
always @(posedge clk) begin   // edge-detect the actual write (DS-asserted)
    palcs_l  <= pal_cs;
    tilecs_l <= pf0_cs|pf1_cs;
    objcs_l  <= objram_cs;
    vbl_irq_l<= vbl_irq;
    irqack_l <= ds_irqack;
    if( pal_cs & ~palcs_l & ~RnW )                palw  = palw  + 1;
    if( (pf0_cs|pf1_cs) & ~tilecs_l & ~RnW )      tilew = tilew + 1;
    if( objram_cs & ~objcs_l & ~RnW )             objw  = objw  + 1;
    if( vbl_irq & ~vbl_irq_l )                    vbl_set = vbl_set + 1;
    if( ds_irqack & ~irqack_l )                   irqack  = irqack  + 1;
end
always @(negedge LVBL) begin
    frcnt = frcnt + 1;
    $display("CNINJA hb: frame=%0d gid=%0d A=%06x pal=%0d tile=%0d obj=%0d | IPLn=%b vbl_set=%0d irqack=%0d",
             frcnt, game_id, {A,1'b0}, palw, tilew, objw, IPLn, vbl_set, irqack);
end



`endif
`else
    // NOMAIN scene replay: the CPU is fully tied off and the video BRAMs in
    // jtcninja_video preload the captured scene via SIMFILE (see README).
    assign cpu_addr  = 0; assign cpu_dout = 0;
    assign UDSWn=1; assign LDSWn=1; assign RnW=1;
    assign rom_cs=0;
    assign pf0_cs=0; assign pf1_cs=0; assign objram_cs=0; assign obj_copy=0;
    assign pal_cs=0; assign prot_cs=0;
    assign snd_wr=0; assign snd_dout=0;
`endif
endmodule
