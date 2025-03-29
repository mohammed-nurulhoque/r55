/* Defines a muticycle shifter where each cycle shifts up to 3 positions
 * val_o is the output of the current cycle and should be fed to val_i in
 * the next cycle if it is not done. The module doesn't internally store the 
 * shifted value as it could be shared with other modules.
 * right_shift and arith_shift should be held constant for the duration of the shift
 * shifting right takes one extra cycle
 * if left shifting and sham_i <=3 it's totally combinatorial.
 */
module shifter3 #(
    parameter int WIDTH=32,
    localparam int WSHAM=$clog2(WIDTH)
) (
    input logic [WIDTH-1:0] val_i,
    input logic [WSHAM-1:0] sham_i,
    input logic right_shift,
    input logic arith_shift,
    input logic clk,
    input logic rst,
    input logic start,

    output logic [WIDTH-1:0] val_o,
    output logic done
);
    logic busy;
    logic [WSHAM-1:0] shift_rem; // register for remaining shift

    logic [1:0] shift_cur; // Amount to shift in this cycle (up to 3)
    wire signed [WIDTH:0] val_ext = {val_i, {(busy && arith_shift) ? val_i[0]: 1'b0}};
    wire [WSHAM-1:0] sham = (!busy) ? sham_i : shift_rem;
    wire [WSHAM-1:0] shift_next = sham - WSHAM'(shift_cur);

    always_comb begin
        shift_cur = (sham > 3) ? 2'd3 : 2'(sham);
        if (!busy && right_shift) shift_cur = 0;
    end

    assign done = busy? shift_next == 0 : !(start && shift_next != 0);
    
    // State machine sequential logic
    always_ff @(posedge clk) begin
        if (rst) busy <= 0;
        else busy <= !done;
        shift_rem <= shift_next;
    end

    // shift operation
    wire [WIDTH:0] val_ext_r = {<<{val_ext}};
    wire [WIDTH-1:0] reversed = WIDTH'($signed(val_ext_r) >>> shift_cur);
    wire [WIDTH-1:0] shifted = {<<{reversed}};
    wire sel_reverse = busy ? (right_shift && shift_next==0) : (start && right_shift && shift_next!=0);
    assign val_o = sel_reverse ? reversed : shifted;
endmodule
