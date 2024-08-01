module Mia #(
  parameter FPGA_D = 0,
  parameter FPGA_M = 0,
  parameter FPGA_Y = 0,
  parameter CLK_TURBO = 0,
  parameter OPT_DISABLE_TURBO = 0
)(
  input  clk,
  input  scs,
  input  sdi,
  input  sdi_d,
  inout  sdo,
  input  sck,
  input  sdo_as_in,

  output        sram_rd,
  output        sram_hwr,
  output        sram_lwr,
  output [15:0] sram_data_out,
  output [15:0] sram_data_in,
  output [23:1] sram_addr_out,

  output reg    rst_out,
  output        bus_req,
  output        spi_busy
);

localparam MAGIC_WORD    = 16'hAABB;
localparam MAGIC_RD      = 16'h0001;
localparam MAGIC_WR      = 16'h0000;

localparam MAGIC_CPU_RST   = 16'h0002;
localparam MAGIC_CPU_UNRST = 16'h0003;

localparam ANSWER_TO_ARM = 16'hBBAA;

//                  :       0       :      1       :      2       :      3       :      4       :      5       :            :      6       :      7       :       8      :
//            ______:               :              :              :              :              :              : ___ ... _________________________________________________
// SCS              \___________________________________________________________________________________________/           :              :              :              :
//                  :               :              :              :              :              :              :            ______________________________________________
// SDO_AS_IN  ______________________________________________________________________________________________________ ... __/               :              :              :
//                  :               :              :              :              :              :              :            :              :              :              :
// SCK        __________//////////_____//////////_____//////////_____//////////_____//////////_____//////////_______ ... ______//////////_____//////////_____//////////___
//                  :               :              :              :              :              :              :            :              :              :              :
// SPI_SDI    ______|  MAGIC_WORD   |   RD / WR    | ADDR [31:16] | ADDR [15:0 ] | SIZE [31:16] | SIZE [15:0 ] |____ ... _________________________________________________
//                  :               :              :              :              :              :              :            :              :              :              :
// SPI_SDO    _____________________________________| ANSWER_2_ARM |_________________________________________________ ... ___|    DATA 0    |    DATA 1    |    DATA 2    |


// PARSE VERSION
localparam VERSION_SIZE = 16;
reg [15:0] rom_version [VERSION_SIZE - 1:0];


initial begin
  //          -1              // -- 00 00 First Word Read
  rom_version[ 0] = 16'h5049; // PI
  rom_version[ 1] = 16'h2046; //  F
  rom_version[ 2] = 16'h4D47; // MG
  rom_version[ 3] = ( (FPGA_Y / 10 + 'h30) << 8 ) | ( (FPGA_Y % 10 + 'h30) << 0 );
  rom_version[ 4] = ( (FPGA_M / 10 + 'h30) << 8 ) | ( (FPGA_M % 10 + 'h30) << 0 );
  rom_version[ 5] = ( (FPGA_D / 10 + 'h30) << 8 ) | ( (FPGA_D % 10 + 'h30) << 0 );
  rom_version[ 6] = 16'h5F5F; // __
  rom_version[ 7] = ( (CLK_TURBO / 10 + 'h30) << 8 ) | ( (CLK_TURBO % 10 + 'h30) << 0 );
  rom_version[ 8] = 16'h4D68; // Mh
  rom_version[ 9] = 16'h7A20; // z
  rom_version[10] = 16'h0000; // 
  rom_version[11] = 16'h0000; // 
  rom_version[12] = 16'h0000; // 
  rom_version[13] = 16'h0000; // 
  rom_version[14] = {15'h0, (OPT_DISABLE_TURBO)? 1'b1 : 1'b0};      // STATUS REGISTER
  rom_version[15] = 16'h0000; // -- never read --
end

// RESET ON-STARTUP ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
reg [31:0] rst_counter = 7;
reg rst;
always @(posedge clk) begin
  if (rst_counter > 0)
    rst_counter <= rst_counter - 'd1;
  
  rst <= (rst_counter == 0)? 1'b0 : 1'b1;
end

// SPI RECEIVE :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
wire sdin = sdo_as_in ? sdi_d : sdi;
wire scs1 = ~scs;
wire scs2 = sdo_as_in;
wire _scs = scs1 | scs2;

reg [15:1] spi_data_shiftreg;
reg [15:0] spi_rx_data;

wire spi_bit_15;
wire spi_data_recv;
reg [31:0] spi_word_cnt;
reg [ 3:0] spi_bit_cnt;

always @(posedge sck or negedge _scs)
	spi_bit_cnt <= (~_scs) ? 'd0 : spi_bit_cnt + 1;

assign spi_bit_15 = (spi_bit_cnt == 15) ? 1 : 0;

always @(posedge sck)
  if (_scs)
	  spi_data_shiftreg <= {spi_data_shiftreg[14:1], sdin};

always @(posedge sck)
	if (spi_bit_15) 
		spi_rx_data <= {spi_data_shiftreg[15:1], sdin};

reg req_zero;
always @(posedge sck or negedge _scs) begin
  if (~_scs)
    req_zero <= 1'b1;
  else if (spi_bit_15) begin
    if (req_zero) begin
      spi_word_cnt <= 'd0;
      req_zero <= 1'b0;
    end
    else
      spi_word_cnt <= spi_word_cnt + 'd1;
  end
end


// Clock - cross _______________________________________________________________

resyncPulse rsync_inst (
  .clk_i(sck),
  .clk_o(clk),
  .in(spi_bit_15),
  .out(spi_data_recv)
);

// MAIN FSM ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
reg [15:0] magic_r_w;
reg [31:0] magic_addr;
reg [31:0] magic_size;
reg [31:0] op_word_cnt;

localparam RST           = 0,
           ST_WAIT_MAGIC = 1,
           ST_RECV_CFG   = 2,
           ST_WRITE      = 3,
           ST_READ       = 4,
           ST_CPU_RST    = 5,
           ST_CPU_UNRST  = 6,
           ST_BUS_DELAY  = 7;

reg [2:0] state, next;

always @(posedge clk)
  state <= (rst)? RST : next;

reg [5:0] delay_cnt;
always @* begin : state_logic
  next = state;
  case (state)
              RST:  next = ST_WAIT_MAGIC;
    ST_WAIT_MAGIC:  if ( (spi_word_cnt == 0) && (spi_rx_data == MAGIC_WORD) && spi_data_recv && scs1)
                      next = ST_RECV_CFG;
      ST_RECV_CFG:  if (spi_word_cnt == 5 && spi_data_recv) begin
                      if      (magic_r_w == MAGIC_WR       ) next = ST_WRITE;
                      else if (magic_r_w == MAGIC_RD       ) next = ST_READ; 
                      else if (magic_r_w == MAGIC_CPU_RST  ) next = ST_CPU_RST; 
                      else if (magic_r_w == MAGIC_CPU_UNRST) next = ST_CPU_UNRST; 
                      else                                   next = ST_WAIT_MAGIC;
                    end
          ST_READ:  if (op_word_cnt == (magic_size >> 1) )      // Statement labels are only allowed in SystemVerilog. :(
                      next = ST_BUS_DELAY;
         ST_WRITE:  if (op_word_cnt == (magic_size >> 1) ) 
                      next = ST_BUS_DELAY;
       ST_CPU_RST:    next = ST_WAIT_MAGIC;
     ST_CPU_UNRST:    next = ST_WAIT_MAGIC;
     ST_BUS_DELAY:  if (delay_cnt == 0)
                      next = ST_WAIT_MAGIC;
          default:  next = RST;
  endcase
end

always @(posedge clk) delay_cnt <= (state == ST_BUS_DELAY)? delay_cnt - 1 : 'd10;


// packed structs doesn't support :(
// multi-dim packed array doesn't support :(
always @(posedge clk) begin
  if (spi_data_recv && (state == ST_RECV_CFG) ) begin
    if      (spi_word_cnt == 1) magic_r_w         <= spi_rx_data;
    else if (spi_word_cnt == 2) magic_addr[31:16] <= spi_rx_data;
    else if (spi_word_cnt == 3) magic_addr[15:0 ] <= spi_rx_data;
    else if (spi_word_cnt == 4) magic_size[31:16] <= spi_rx_data;
    else if (spi_word_cnt == 5) magic_size[15:0 ] <= spi_rx_data;
  end
end

always @(posedge clk) begin
  if (state == ST_WRITE || state == ST_READ) begin
    if (spi_data_recv)
      op_word_cnt <= op_word_cnt + 'd1;
  end
  else
    op_word_cnt <= 'd0;
end

// SRAM MEMORY :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
reg [15:0] _l_data;
reg [31:0] _l_addr;
reg write_stb;
always @(posedge clk) begin
  if (spi_data_recv) begin
    _l_data <= spi_rx_data;
    _l_addr <= magic_addr + (op_word_cnt << 1);
  end

  write_stb <= spi_data_recv & (state == ST_WRITE);
end

assign sram_rd       = 1'b0;
assign sram_hwr      = write_stb;
assign sram_lwr      = write_stb;
assign sram_data_out = (write_stb)? _l_data : 'd0;
assign sram_addr_out = (write_stb)? _l_addr[23:1] : 'd0;

// RESET / BUS REQUEST :::::::::::::::::::::::::::::::::::::::::::::::::::::::::
reg bus_req_d;
always @(posedge clk)
  bus_req_d <= bus_req;

always @(posedge clk)
  if (rst)
    rst_out <= 1'b1;
  else if (state == ST_CPU_RST)
    rst_out <= 1'b1;
  else if (state == ST_CPU_UNRST)
    rst_out <= 1'b0;

assign bus_req = ( (state == ST_READ) || (state == ST_WRITE) || (state == ST_BUS_DELAY) )? 1'b1 : 1'b0;

// ANSWER MAGIC TO ARM :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

reg [15:0] tx_data_send = 0;
reg [15:0] tx_data = 0;

always @(negedge sck)
  if (spi_bit_cnt == 0)
    tx_data <= tx_data_send;
  else
    tx_data <= {tx_data[14:0],1'b0};
    

always @(posedge sck)
  if (spi_bit_15) begin
    if ((spi_word_cnt == 'd0) && (state == ST_RECV_CFG))
      tx_data_send <= ANSWER_TO_ARM;
    else if (state == ST_READ)
      tx_data_send <= rom_version[op_word_cnt];
    else
      tx_data_send <= 'd0;
  end

assign sdo = ( ( (state == ST_RECV_CFG) || (state == ST_READ) ) ) ? tx_data[15] : 1'b0;
assign spi_busy = ( state == ST_WAIT_MAGIC ) ? 1'b0 : 1'b1;

endmodule // : Mia


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module resyncPulse (
  input wire clk_i,
  input wire clk_o,
  input wire in,
  output wire out
);

reg l_pulse = 1'b0;
always @(posedge clk_i) 
	if (in) l_pulse <= ~l_pulse;

reg step2, step3, step4;
reg [2:0] rsync;
always @(posedge clk_o) begin
	rsync[0]   <= l_pulse;
  rsync[2:1] <= rsync[1:0];
end

assign out = rsync[2] ^ rsync[1];

endmodule
