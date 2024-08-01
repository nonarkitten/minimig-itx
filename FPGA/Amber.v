// Copyright 2006, 2007 Dennis van Weeren
// 
// This file is part of Minimig
// 
// Minimig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
// 
// Minimig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http:         // www.gnu.org/licenses/>.
// 
// 
// 
// This is Amber
// Amber is a scandoubler to allow connection to a VGA monitor. 
// In addition, it can overlay an OSD (on-screen-display) menu.
// Amber also has a pass-through mode in which
// the video output can be connected to an RGB SCART input.
// The meaning of _hsync_out and _vsync_out is then:
// _vsync_out is fixed high (for use as RGB enable on SCART input).
// _hsync_out is composite sync output.
// 
// 10-01-2006   - first serious version
// 11-01-2006   - done lot's of work, Amber is now finished
// 29-12-2006   - added support for OSD overlay
// ----------
// JB:
// 2008-02-26   - synchronous 28 MHz version
// 2008-02-28   - horizontal and vertical interpolation
// 2008-02-02   - hfilter/vfilter inputs added, unused inputs removed
// 2008-12-12   - useless scanline effect implemented
// 2008-12-27   - clean-up
// 2009-05-24   - clean-up & renaming
// 2009-08-31   - scanlines synthesis option
// 2010-05-30   - htotal changed
// 
// SB:
// 2014-05-05  - changed OSD background to no dimmed scanlines at 31KHz
//
// RNC:
// 2022-03-04  - fixed scanlines to not reduce brightness
// 2022-03-22  - changed h-filter to simple kalman

module Amber
(
    input   clk28m,
    input   [1:0] lr_filter,                            // interpolation filters settings for low resolution
    input   [1:0] hr_filter,                            // interpolation filters settings for high resolution
    input   [1:0] scanline,                             // scanline effect enable
    input   [8:1] htotal,                               // video line length
    input   hires,                                      // display is in hires mode (from bplcon0)
    input   dblscan,                                    // enable VGA output (enable scandoubler)
    input   osd_blank,                                  // OSD overlay enable (blank normal video)
    input   osd_pixel,                                  // OSD pixel(video) data
    input   [3:0] red_in,                               // red componenent video in
    input   [3:0] grn_in,                               // grn component video in
    input   [3:0] blu_in,                               // blu component video in
    input   _hsync_in,                                  // horizontal synchronisation in
    input   _vsync_in,                                  // vertical synchronisation in
    input   _csync_in,                                  // composite synchronization in
    output  reg [3:0] red_out,                          // red componenent video out
    output  reg [3:0] grn_out,                          // grn component video out
    output  reg [3:0] blu_out,                          // blu component video out
    output      _hsync_out,                             // horizontal synchronisation out
    output      _vsync_out                              // vertical synchronisation out
);

    // Local signals
    wire     [3:0] t_red;
    wire     [3:0] t_grn;
    wire     [3:0] t_blu;

    wire     [3:0] f_red;
    wire     [3:0] f_grn;
    wire     [3:0] f_blu;

    wire           t_osd_bg;
    wire           t_osd_fg;

    // signal after horizontal filter
    wire    [3:0] red;
    wire    [3:0] grn;
    wire    [3:0] blu;

    reg     _hsync_in_del;                                  // delayed horizontal synchronisation input
    reg     hss;                                            // horizontal sync start
    wire    eol;                                            // end of scan-doubled line

    reg     hfilter;                                        // horizontal interpolation enable
    //reg     vfilter;                                        // vertical interpolation enable
        
    reg     scanline_ena;                                   // signal active when the scan-doubled line is displayed

    // horizontal filter
    reg [5:0] red_filter;
    reg [5:0] grn_filter;
    reg [5:0] blu_filter;


    // -----------------------------------------------------------------------------

    // local horizontal counters for scan doubling 
    reg [10:0] wr_ptr;                                      // line buffer write pointer
    reg [10:0] rd_ptr;                                      // line buffer read pointer

    reg [15:0] lbf [1023:0];                                // line buffer for scan doubling (there are 908/910 hires pixels in every line)
    reg [15:0] lbfo;                                        // line buffer output register

    // end of scan-doubled line
    assign eol = (rd_ptr == {htotal[8:1],2'b11});

    // horizontal sync start (falling edge detection)
    always @(posedge clk28m) begin
        // delayed hsync for edge detection
        _hsync_in_del <= _hsync_in;
        hss <= ~_hsync_in & _hsync_in_del;
        // line buffer write pointer
        wr_ptr <= (hss) ? 0 : (wr_ptr + 1);
        // line buffer read pointer
        rd_ptr <= (hss | eol) ? 0 : (rd_ptr + 1);
        // scanline enable
        scanline_ena <= (hss) ? 0 : (eol) ? 1 : scanline_ena;
        // horizontal interpolation enable
        if (hss) hfilter <= hires ? hr_filter[0] : lr_filter[0]; 
    end
        
    always @(posedge clk28m) begin
        red_filter <= red_filter - (red_filter >> 2) + red_in;
        grn_filter <= grn_filter - (grn_filter >> 2) + grn_in;
        blu_filter <= blu_filter - (blu_filter >> 2) + blu_in;
    end    

    assign red = hfilter ? red_filter[5:2] : red_in;
    assign grn = hfilter ? grn_filter[5:2] : grn_in;
    assign blu = hfilter ? blu_filter[5:2] : blu_in;

    always @(posedge clk28m) begin
        // line buffer write
        lbf[wr_ptr[10:1]] <= { 1'b0, _hsync_in, osd_blank, osd_pixel, red, grn, blu };
        // line buffer read
        lbfo <= lbf[rd_ptr[9:0]];
    end
         
    // output pixel generation - OSD mixer and vertical interpolation     
    assign f_red = dblscan ? (lbfo[11:8]) : red_in;
    assign f_grn = dblscan ? (lbfo[ 7:4]) : grn_in;
    assign f_blu = dblscan ? (lbfo[ 3:0]) : blu_in;

    assign _hsync_out = dblscan ? lbfo[14] : _csync_in;
    assign _vsync_out = dblscan ? _vsync_in : 1'b1;

    assign t_osd_bg = dblscan ? lbfo[13] : osd_blank;
    assign t_osd_fg = dblscan ? lbfo[12] : osd_pixel;

    assign t_red = t_osd_bg ? (t_osd_fg ? 4'b1110 : (f_red / 2)) : f_red;
    assign t_grn = t_osd_bg ? (t_osd_fg ? 4'b1110 : (f_grn / 2)) : f_grn;
    assign t_blu = t_osd_bg ? (t_osd_fg ? 4'b1110 : (f_blu / 2) + 4'b0100) : f_blu;

    always @(posedge clk28m) begin
        if (scanline[0]) begin
            // Dark lines                                         // F                 L L L L L L L W  \   W white
            if (scanline_ena) begin                               // E               L                  |   L light
                red_out <= { t_red[2:0], 1'b1 } & {4{t_red[3]}};  // D                             D    |   D dark
                grn_out <= { t_grn[2:0], 1'b1 } & {4{t_grn[3]}};  // C             L                    |   B black
                blu_out <= { t_blu[2:0], 1'b1 } & {4{t_blu[3]}};  // B                           D      |
                                                                  // A           L                      |
            // Light lines                                        // 9                         D        |
            end else begin                                        // 8         L                        \_ Output
                red_out <= { t_red[2:0], 1'b0 } | {4{t_red[3]}};  // 7                       D          /  Levels
                grn_out <= { t_grn[2:0], 1'b0 } | {4{t_grn[3]}};  // 6       L                          |
                blu_out <= { t_blu[2:0], 1'b0 } | {4{t_blu[3]}};  // 5                     D            |
            end                                                   // 4     L                            |
                                                                  // 3                   D              |
        end else begin                                            // 2   L                              |
                red_out <= t_red;                                 // 1                 D                |
                grn_out <= t_grn;                                 // 0 B D D D D D D D                  /
                blu_out <= t_blu;                                 //   0 1 2 3 4 5 6 7 8 9 A B C D E F  <-- Input Level
        end
    end

endmodule




