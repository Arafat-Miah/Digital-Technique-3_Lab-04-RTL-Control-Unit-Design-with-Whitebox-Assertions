`include "audioport.svh"
import audioport_pkg::*;

module control_unit
  (
   input  logic                        clk,
   input  logic                        rst_n,
   input  logic                        PSEL,
   input  logic                        PENABLE,
   input  logic                        PWRITE,
   input  logic [31:0]                 PADDR,
   input  logic [31:0]                 PWDATA,
   input  logic                        req_in,

   output logic [31:0]                 PRDATA,
   output logic                        PSLVERR,
   output logic                        PREADY,
   output logic                        irq_out,
   output logic [31:0]                 cfg_reg_out,
   output logic [31:0]                 level_reg_out,
   output logic [DSP_REGISTERS*32-1:0]  dsp_regs_out,
   output logic                        cfg_out,
   output logic                        clr_out,
   output logic                        level_out,
   output logic                        tick_out,
   output logic [23:0]                 audio0_out,
   output logic [23:0]                 audio1_out,
   output logic                        play_out
   );

  // ============================================================
  // Ex1 internal signals (must match SVA expectations)
  // ============================================================
  logic [$clog2(AUDIOPORT_REGISTERS+2)-1:0] rindex;
  logic                                    apbwrite;
  logic                                    apbread;

  logic                                    play_r;
  logic                                    req_r;

  // ============================================================
  // Ex2 internal signals (must exist for SVA binding)
  // ============================================================
  logic                                    start;
  logic                                    stop;
  logic                                    clr;
  logic                                    irqack;

  logic                                    irq_r;

  // Register bank (packed 2D for SVA bindings)
  logic [AUDIOPORT_REGISTERS-1:0][31:0]     rbank_r;

  // Left FIFO (style-2: state + next-state)
  logic [AUDIO_FIFO_SIZE-1:0][23:0]         ldata_r,   ldata_ns;
  logic [$clog2(AUDIO_FIFO_SIZE)-1:0]       lhead_r,   lhead_ns;
  logic [$clog2(AUDIO_FIFO_SIZE)-1:0]       ltail_r,   ltail_ns;
  logic                                    llooped_r, llooped_ns;
  logic                                    lempty;
  logic                                    lfull;
  logic [23:0]                             lfifo;

  // Right FIFO (style-2)
  logic [AUDIO_FIFO_SIZE-1:0][23:0]         rdata_r,   rdata_ns;
  logic [$clog2(AUDIO_FIFO_SIZE)-1:0]       rhead_r,   rhead_ns;
  logic [$clog2(AUDIO_FIFO_SIZE)-1:0]       rtail_r,   rtail_ns;
  logic                                    rlooped_r, rlooped_ns;
  logic                                    rempty;
  logic                                    rfull;
  logic [23:0]                             rfifo;

  // ============================================================
  // APB fixed outputs
  // ============================================================
  always_comb begin
    PREADY  = 1'b1;
    PSLVERR = 1'b0;
  end

  // ============================================================
  // APB access decode + address->index decode
  // ============================================================
  always_comb begin
    apbwrite = (PSEL && PENABLE && PWRITE  && PREADY);
    apbread  = (PSEL && PENABLE && !PWRITE && PREADY);
  end

  always_comb begin
    if (PSEL)
      //rindex = (PADDR - AUDIOPORT_START_ADDRESS) >> 2;
      rindex = (($unsigned(PADDR - AUDIOPORT_START_ADDRESS)) >> 2);
    else
      rindex = '0;
  end

  // ============================================================
  // Command decoder (pulses)
  // ============================================================
  always_comb begin
    start  = 1'b0;
    stop   = 1'b0;
    clr    = 1'b0;
    irqack = 1'b0;

    cfg_out   = 1'b0;
    clr_out   = 1'b0;
    level_out = 1'b0;

    if (apbwrite && (PADDR == CMD_REG_ADDRESS)) begin
      unique case (PWDATA)
        CMD_START:   start  = 1'b1;
        CMD_STOP:    stop   = 1'b1;
        CMD_IRQACK:  irqack = 1'b1;
        CMD_CFG:     cfg_out   = 1'b1;
        CMD_LEVEL:   level_out = 1'b1;

        CMD_CLR: begin
          if (!play_r) begin
            clr     = 1'b1;
            clr_out = 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  // ============================================================
  // play_r and req_r registers
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      play_r <= 1'b0;
    end
    else begin
      if (start && !play_r)
        play_r <= 1'b1;
      else if (stop && play_r)
        play_r <= 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      req_r <= 1'b0;
    else
      req_r <= play_r ? req_in : 1'b0;
  end

  always_comb begin
    tick_out = play_r ? req_r : 1'b0;
  end

  assign play_out = play_r;

  // ============================================================
  // Register bank write + STATUS_REG internal behavior (FIX)
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rbank_r <= '0;
    end
    else begin
      // 1) Normal APB writes into register bank (exclude FIFO addresses)
      if (apbwrite
          && (rindex < AUDIOPORT_REGISTERS)
          && (PADDR != LEFT_FIFO_ADDRESS)
          && (PADDR != RIGHT_FIFO_ADDRESS)) begin
        rbank_r[rindex] <= PWDATA;
      end
      else begin
        // no bus write -> leave as-is
        rbank_r <= rbank_r;
      end

      // 2) STATUS_REG bit STATUS_PLAY must follow START/STOP,
      //    but bus write to STATUS_REG has priority over internal update.
      if (!(apbwrite && (PADDR == STATUS_REG_ADDRESS))) begin
        if (start)
          rbank_r[STATUS_REG_INDEX][0] <= 1'b1;
        else if (stop)
          rbank_r[STATUS_REG_INDEX][0] <= 1'b0;
      end
    end
  end

  // ============================================================
  // Required register outputs
  // ============================================================
  assign level_reg_out = rbank_r[LEVEL_REG_INDEX];
  assign cfg_reg_out   = rbank_r[CFG_REG_INDEX];
  assign dsp_regs_out  = rbank_r[DSP_REGS_END_INDEX:DSP_REGS_START_INDEX];

  // ============================================================
  // FIFO helper: increment with wrap
  // ============================================================
  function automatic [$clog2(AUDIO_FIFO_SIZE)-1:0] inc_ptr(
    input [$clog2(AUDIO_FIFO_SIZE)-1:0] ptr
  );
    if (ptr == AUDIO_FIFO_SIZE-1)
      inc_ptr = '0;
    else
      inc_ptr = ptr + 1'b1;
  endfunction

  // ============================================================
  // Left FIFO
  // ============================================================
  logic lpop_apb;
  assign lempty = (lhead_r == ltail_r) && !llooped_r;
  assign lfull  = (lhead_r == ltail_r) &&  llooped_r;

  always_comb lfifo = lempty ? 24'h0 : ldata_r[ltail_r];

  assign lpop_apb = apbread && (PADDR == LEFT_FIFO_ADDRESS);

  always_comb begin
    ldata_ns   = ldata_r;
    lhead_ns   = lhead_r;
    ltail_ns   = ltail_r;
    llooped_ns = llooped_r;

    if (clr) begin
      ldata_ns   = '0;
      lhead_ns   = '0;
      ltail_ns   = '0;
      llooped_ns = 1'b0;
    end
    else begin
      if (apbwrite && (PADDR == LEFT_FIFO_ADDRESS) && !lfull) begin
        ldata_ns[lhead_r] = PWDATA[23:0];
        lhead_ns = inc_ptr(lhead_r);
        if (inc_ptr(lhead_r) == ltail_r)
          llooped_ns = 1'b1;
      end

      if ((tick_out || lpop_apb) && !lempty) begin
        ltail_ns = inc_ptr(ltail_r);
        if (inc_ptr(ltail_r) == lhead_r)
          llooped_ns = 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ldata_r   <= '0;
      lhead_r   <= '0;
      ltail_r   <= '0;
      llooped_r <= 1'b0;
    end
    else begin
      ldata_r   <= ldata_ns;
      lhead_r   <= lhead_ns;
      ltail_r   <= ltail_ns;
      llooped_r <= llooped_ns;
    end
  end

  // ============================================================
  // Right FIFO
  // ============================================================
  logic rpop_apb;
  assign rempty = (rhead_r == rtail_r) && !rlooped_r;
  assign rfull  = (rhead_r == rtail_r) &&  rlooped_r;

  always_comb rfifo = rempty ? 24'h0 : rdata_r[rtail_r];

  assign rpop_apb = apbread && (PADDR == RIGHT_FIFO_ADDRESS);

  always_comb begin
    rdata_ns   = rdata_r;
    rhead_ns   = rhead_r;
    rtail_ns   = rtail_r;
    rlooped_ns = rlooped_r;

    if (clr) begin
      rdata_ns   = '0;
      rhead_ns   = '0;
      rtail_ns   = '0;
      rlooped_ns = 1'b0;
    end
    else begin
      if (apbwrite && (PADDR == RIGHT_FIFO_ADDRESS) && !rfull) begin
        rdata_ns[rhead_r] = PWDATA[23:0];
        rhead_ns = inc_ptr(rhead_r);
        if (inc_ptr(rhead_r) == rtail_r)
          rlooped_ns = 1'b1;
      end

      if ((tick_out || rpop_apb) && !rempty) begin
        rtail_ns = inc_ptr(rtail_r);
        if (inc_ptr(rtail_r) == rhead_r)
          rlooped_ns = 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_r   <= '0;
      rhead_r   <= '0;
      rtail_r   <= '0;
      rlooped_r <= 1'b0;
    end
    else begin
      rdata_r   <= rdata_ns;
      rhead_r   <= rhead_ns;
      rtail_r   <= rtail_ns;
      rlooped_r <= rlooped_ns;
    end
  end

  // ============================================================
  // Outputs
  // ============================================================
  assign audio0_out = lfifo;
  assign audio1_out = rfifo;

  // ============================================================
  // PRDATA (FIFO reads must have priority over rbank)
  // ============================================================
  always_comb begin
    PRDATA = 32'h0;

    if (PSEL && apbread) begin
      if (PADDR == LEFT_FIFO_ADDRESS)
        PRDATA = {8'h00, lfifo};
      else if (PADDR == RIGHT_FIFO_ADDRESS)
        PRDATA = {8'h00, rfifo};
      else if (rindex < AUDIOPORT_REGISTERS)
        PRDATA = rbank_r[rindex];
      else
        PRDATA = 32'h0;
    end
  end

  // ============================================================
  // IRQ logic
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq_r <= 1'b0;
    end
    else if (!play_r) begin
      irq_r <= 1'b0;
    end
    else if (stop || irqack) begin
      irq_r <= 1'b0;
    end
    else if (lempty && rempty) begin
      irq_r <= 1'b1;
    end
  end

  assign irq_out = irq_r;

endmodule
