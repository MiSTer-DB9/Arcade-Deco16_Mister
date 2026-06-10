/*  See jtcninja_game.v header.

    Single deco16ic playfield renderer for cninja (Joe & Mac).
    Adapted from cores/cop/hdl/jtcop_bac06.v (the BAC06 ancestor). cninja uses
    fixed 64x32 maps (DECO_64x32). Basic X/Y scroll; rowscroll/colscroll TODO.

    Tile RAM index (MAME deco16ic basic_8x8/16x16 mapper, 64x32):
       idx = col[4:0] | row[4:0]<<5 | col[5]<<10
    Tile RAM word: [15:12]=palette, [11:0]=tile code (+ external bank bits).
    Tiles are 4bpp; one 32-bit ROM word holds an 8-pixel row (4 planes).

    Produces an 8-bit line-buffer pixel: {palette[3:0], colour[3:0]}.
*/
module jtcninja_pf #(
    parameter TILE16 = 1,           // 1 = 16x16 tiles, 0 = 8x8
    parameter DUMPID = 0            // !=0 : SIMULATION dump of tile fetches to pf_dump_<id>.tr
)(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             flip,

    // Map height select (deco16ic set_pfN_size): 0 = 64x32 (DECO_64x32),
    // 1 = 64x64 (DECO_64x64). cninja's maps are all 64x32; Dark Seal's
    // tilegen0 is 64x64. Runtime config so one engine serves both boards.
    input             tall,

    // Plane-pair order. The gfx_layout planeoffset differs between boards:
    //   cninja tilelayout {FRAC+8,FRAC,8,0}  -> planes 2,3 in the low ROM half
    //   darkseal seallayout {8,0,FRAC+8,FRAC} -> planes 0,1 in the low half
    // so the two 16-bit plane pairs in draw_data are swapped. pswap=1 swaps them.
    input             pswap,

    input      [15:0] scrx,         // X scroll
    input      [15:0] scry,         // Y scroll
    input      [ 2:0] bank,         // 16x16 tile bank (high code bits)

    // timing (from the shared vtimer)
    input      [ 8:0] vrender,
    input      [ 8:0] hdump,
    input             hs,

    // tile RAM (video read port). 12-bit for the 64x64 case (4096 tiles);
    // 64x32 uses the low 2048 (bit 11 = 0).
    output reg [11:0] ram_addr,
    input      [15:0] ram_data,

    // tile ROM
    output reg        rom_cs,
    output reg [19:2] rom_addr,    // 18b dword: 16x16 tiles2 needs 13-bit tile (bank[0]=bit12)
    input      [31:0] rom_data,
    input             rom_ok,

    output     [ 7:0] pxl           // {pal[3:0], col[3:0]}
);

// ---- scan: read tile RAM, get id/pal ----
reg  [ 9:0] hn;                     // running horizontal tile-pixel position
reg  [ 9:0] veff;                   // effective vertical (vrender + scry)
reg  [11:0] tile_id;
reg  [ 3:0] tile_pal;
reg  [ 5:0] colf, rowf;
reg         scan_busy, draw, HSl;
reg  [ 1:0] ram_good;
reg  [ 5:0] tilecnt;

wire [9:0] vsum = {1'b0, flip ? 9'd255-vrender : vrender} + scry[9:0];

// Tile-RAM index. The deco16ic uses DIFFERENT mappers per tile size, and the
// 16x16 mapper carries an extra row bit for 64-tall maps (deco16ic.cpp:291):
//   16x16: deco16_scan_rows = (col&0x1f) | (row&0x1f)<<5 | (col&0x20)<<5
//                             | (row&0x20)<<6   <- the (row&0x20) term only
//                             reaches RAM on a 64x64 map (tall=1)
//    8x8 : TILEMAP_SCAN_ROWS = row*64 + col   (standard row-major; 6-bit row
//          on a tall map, 5-bit on 64x32)
// Using the 16x16 mapper for 8x8 spread each text row to 2x the pitch (a blank
// line between every HUD line). col=hn>>tsz, row=veff>>tsz.
always @* begin
    colf = 0; rowf = 0;
    if( TILE16 )
        ram_addr = tall ? { veff[9], hn[9], veff[8:4], hn[8:4] }   // {row5,col5,row4:0,col4:0}
                        : { 1'b0,   hn[9], veff[8:4], hn[8:4] };   // 64x32 {col5,row4:0,col4:0}
    else
        ram_addr = tall ? { veff[8:3], hn[8:3] }                   // row[5:0]*64 + col[5:0]
                        : { 1'b0, veff[7:3], hn[8:3] };            // 64x32 row[4:0]*64+col
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        scan_busy<=0; draw<=0; HSl<=0; hn<=0; ram_good<=0; tilecnt<=0;
        tile_id<=0; tile_pal<=0; veff<=0;
    end else begin
        ram_good <= { ram_good[0], 1'b1 };
        HSl <= hs;
        draw <= 0;
        if( HSl && !hs ) begin       // start of line
            hn       <= scrx[9:0];
            veff     <= vsum;
            tilecnt  <= 0;
            ram_good <= 0;
            scan_busy<= 1;
        end
        if( scan_busy && ram_good[1] && !draw && !draw_busy ) begin
            tile_id  <= ram_data[11:0];
            tile_pal <= ram_data[15:12];
            draw     <= 1;
            hn       <= hn + (TILE16 ? 10'd16 : 10'd8);
            tilecnt  <= tilecnt + 1'd1;
            ram_good <= 0;
            // cover the full 256px width: 16px tiles need ~17, 8px tiles need ~33
            if( tilecnt > (TILE16 ? 6'd17 : 6'd33) ) scan_busy <= 0;
        end
    end
end

// ---- draw: fetch tile ROM, shift 4bpp pixels into the line buffer ----
reg  [31:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         draw_busy, half, rom_good, get_hsub;
reg  [ 8:0] buf_waddr;
reg         buf_we;
reg         fresh;       // rom_ok has deasserted since this fetch was issued
                         // (guards against sampling stale data from the prior read)
// 4 planes in the 32-bit read: plane p = bit7 of byte p (byte0=d[7:0]..byte3=d[31:24]).
// MSB-first pixels => shift draw_data<<1. draw_pxl={p3,p2,p1,p0}.
// Verified against the ACTUAL sim ROM fetches vs MAME gfxdecode (all planes match).
// draw_pxl = {plane3,plane2,plane1,plane0}; pswap exchanges the two plane pairs
// for boards whose gfx_layout puts planes 0,1 in the low ROM half (darkseal).
wire [ 3:0] draw_pxl = pswap ? { draw_data[15], draw_data[7], draw_data[31], draw_data[23] }
                             : { draw_data[31], draw_data[23], draw_data[15], draw_data[7] };
wire [ 7:0] buf_wdata = { tile_pal, draw_pxl };
wire [ 8:0] buf_waflip = !flip ? buf_waddr : 9'h100 - buf_waddr;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        draw_busy<=0; draw_cnt<=0; buf_waddr<=0; rom_good<=0; buf_we<=0;
        rom_cs<=0; half<=0; get_hsub<=0; draw_data<=0; rom_addr<=0; fresh<=0;
    end else begin
        rom_good <= rom_ok;
        if( rom_cs && !rom_ok ) fresh <= 1;   // saw rom_ok low -> new read in flight
        if( HSl && !hs ) get_hsub <= 1;
        if( draw ) begin
            draw_busy <= 1; half <= 0;
            if( TILE16 )
                rom_addr <= { bank[0], tile_id, 1'b1, veff[3:0] };// 18b, half@[6]; left 8px first
            else
                rom_addr <= { 3'd0, tile_id, veff[2:0] };        // 18 bits (chars: bank unused)
            draw_cnt <= 0; rom_cs <= 1; rom_good <= 0; fresh <= 0; get_hsub <= 0;
            if( get_hsub )
                buf_waddr <= TILE16 ? 9'd0 - {5'd0,hn[3:0]} : 9'd0 - {6'd0,hn[2:0]};
        end
        if( !buf_we && rom_cs && fresh && rom_good && rom_ok && draw_cnt==0 ) begin
            draw_data <= rom_data;
            rom_cs    <= 0;
            buf_we    <= 1;
            draw_cnt  <= 7;
            fresh     <= 0;
        end
        if( buf_we ) begin
            draw_data <= draw_data << 1;
            draw_cnt  <= draw_cnt - 1'd1;
            buf_waddr <= buf_waddr + 9'd1;
            if( draw_cnt==0 ) begin
                buf_we <= 0;
                if( !TILE16 || half ) begin
                    draw_busy <= 0; rom_cs <= 0;
                end else begin
                    rom_addr[6] <= ~rom_addr[6];    // second 8px half of 16px row
                    rom_cs <= 1; rom_good <= 0; fresh <= 0; half <= 1; draw_cnt <= 0;
                end
            end
        end
    end
end

`ifdef SIMULATION
// Tile-fetch dump: logs (tile code, gfx rom address, 32-bit gfx data) per fetch
// so it can be diffed against MAME's tilemap + gfxdecode. Enabled per-instance
// via DUMPID (e.g. bg=2). Captures the moment draw_data <= rom_data.
integer pf_fd;
reg [11:0] pf_dcnt;
reg [ 8:0] pf_vrl;
reg [11:0] pf_frcnt;     // frame counter (vrender wrap), to capture the INTRO not boot
wire pf_cap = !buf_we && rom_cs && fresh && rom_good && rom_ok && draw_cnt==0;
initial begin
    pf_dcnt = 0; pf_frcnt = 0; pf_vrl = 0;
    if( DUMPID!=0 ) pf_fd = $fopen($sformatf("pf_dump_%0d.tr", DUMPID), "w");
end
always @(posedge clk) begin
    pf_vrl <= vrender;
    if( vrender < pf_vrl ) pf_frcnt <= pf_frcnt + 12'd1;   // top-of-frame wrap
    // capture only well after boot (frame >=180) so the dump holds intro fetches
    if( DUMPID!=0 && pf_cap && pf_frcnt>=12'd180 && pf_dcnt < 12'd400 ) begin
        $fwrite(pf_fd, "t=%03x a=%05x d=%08x vr=%0d half=%b\n",
                tile_id, rom_addr, rom_data, vrender, half);
        pf_dcnt <= pf_dcnt + 12'd1;
    end
end
`endif

jtframe_linebuf #(.DW(8), .AW(9)) u_buffer(
    .clk     ( clk        ),
    .LHBL    ( ~hs        ),
    .wr_addr ( buf_waflip ),
    .wr_data ( buf_wdata  ),
    .we      ( buf_we     ),
    .rd_addr ( hdump      ),
    .rd_data (            ),
    .rd_gated( pxl        )
);

endmodule
