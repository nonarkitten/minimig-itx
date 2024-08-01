module M68KBridge 
(
  input	clk28m,
  input	clk,      // CPU & internal bus clock

  // M68k External bus
  input	       _as,
  input	        r_w,
  input        _lds,
  input	       _uds,
  output       _dtack_cpu,
  input	[23:1] address,
  inout	[15:0] data,

  // Internal bus
  output	      rd,
  output	      hwr,
  output	      lwr,
  output [23:1] address_out,
  output [15:0] data_out,
  input	 [15:0] data_in,

  // Internal control signals
  input	  cck,					// colour clock enable, active when dma can access the memory bus
  output  turbo,				// indicates current CPU speed mode
  input	  dbs,					// data bus slowdown (access to chip ram or custom registers)
  output	bls, 					// blitter slowdown, tells the blitter that CPU wants the bus

  output [5:0]_dbg
);

localparam RD_DELAY = 3;        // clk_28 ticks from out address latch to data arrival (taking into account CCK)
//localparam WR_DELAY = 3;      // clk_28 ticks from AS negedge to valid data latch @ CPU BUS
localparam WR_DELAY_CMPLT = 3;  // 0..4

reg _l28_as, _l28_as_d, l28_r_w, _l28_uds, _l28_lds;

wire [23:1] addr_latch;              // Read Addr
reg  [15:0] data_out_rd;             // Read data
wire [15:0] data_out_wr;             // Write Data


always @(posedge clk28m) begin
  _l28_as   <= _as;
  _l28_as_d <= _l28_as;
   l28_r_w  <=  r_w;
  _l28_uds <= _uds;
  _l28_lds <= _lds;
end

reg dtack_r;

wire _l28_as_fe = ~_l28_as & _l28_as_d;
wire enable     = ~_l28_as & ~cck;

reg [2:0] cck_cnt;
always @(posedge clk28m)
  cck_cnt <= (~cck)?  cck_cnt + 3'd1 : 3'd0;

reg fl_waitcck;
always @(posedge clk28m) begin
  if (_l28_as)
    fl_waitcck <= 1'b0;
  else if (cck_cnt == 0)
    fl_waitcck <= 1'b1;
end

// Read side ...................................................................
reg [7:0] cnt_read = 8'd0;

wire rd_ack   = _l28_as_fe & l28_r_w;
wire rd_valid = (cnt_read == RD_DELAY) ? 1'b1 : 1'b0;

always @(posedge clk28m) begin
  if (_l28_as)
    cnt_read <= 'd0;
  else if ( cnt_read < RD_DELAY) begin
    cnt_read <= (l28_r_w & enable)? cnt_read + 1 : 'd0;
  end
end

reg _dbg_rd;
always @(posedge clk28m)
  _dbg_rd <= ~(l28_r_w & enable) & (cnt_read < RD_DELAY) & (cnt_read > 0);

reg rd_valid_d;
always @(posedge clk28m)
  rd_valid_d <= rd_valid;

wire rd_cmplt = ~rd_valid_d & rd_valid;

always @(posedge clk28m) begin
  if (rd_cmplt)
    data_out_rd <= data_in;
end

// Write side ..................................................................
reg [7:0] cnt_wr_waitcmplt = 8'd0;

wire wr_data_v = ~l28_r_w & ~_l28_as;
wire wr_ready  = (cnt_wr_waitcmplt >= WR_DELAY_CMPLT) ? 1'b1 : 1'b0;

assign data_out_wr = data;

always @(posedge clk28m) begin
  if (_l28_as)
    cnt_wr_waitcmplt <= 'd0;
  else begin
    if (cnt_wr_waitcmplt < WR_DELAY_CMPLT) 
      cnt_wr_waitcmplt <= (wr_data_v & enable)? cnt_wr_waitcmplt + 1 : 'd0;
  end
end

reg wr_ready_d;
always @(posedge clk28m)
  wr_ready_d <= wr_ready;

wire wr_cmplt = ~wr_ready_d & wr_ready;

// RD / WR Address latch .......................................................

assign addr_latch = address;

// DTACK .......................................................................

reg dtack_r_d;
always @(posedge clk28m) begin
  if (_l28_as)
    dtack_r <= 1'b1;
  else if (wr_cmplt | rd_cmplt)
    dtack_r <= 1'b0;

  dtack_r_d <= dtack_r;
end

// Tri-state output ............................................................

assign doe = (r_w & ~_as) & ~dtack_r;

//Output assignments ...........................................................
reg l_as, l_dtack, lr_w;
always @(posedge clk)
	{lr_w, l_as,l_dtack} <= {r_w, _as, _dtack_cpu};

reg [23:1] r_addr_out;
always @(posedge clk)
	r_addr_out[23:1] <= address[23:1];

assign address_out = r_addr_out;
assign data_out    = data_out_wr;

assign rd  = (enable & l28_r_w & dtack_r & fl_waitcck & ~cck);
assign hwr = (~l_as & ~lr_w & ~_l28_uds & wr_data_v & ~cck);
assign lwr = (~l_as & ~lr_w & ~_l28_lds & wr_data_v & ~cck);

assign data[15:0] = (doe) ? data_out_rd : 16'bzzzz_zzzz_zzzz_zzzz;
assign _dtack_cpu = dtack_r | dtack_r_d | _l28_as;

assign turbo = 1'b0;
assign bls = (dbs & ~l_as & dtack_r);

endmodule
