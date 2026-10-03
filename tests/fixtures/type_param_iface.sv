interface type_param_iface #(
    parameter type DATA_TYPE = logic [31:0],
    parameter type USER_TYPE = logic [31:0],
    parameter bit ENABLE_LOGGING = 1'b0
) (
    input wire i_clk
);
    DATA_TYPE data;
    USER_TYPE user;
    logic vld;
endinterface
