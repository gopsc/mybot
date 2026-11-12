#pragma once

#include "json.hpp"

namespace bot {
class RobotStruct;
namespace agent {
struct AgentModeConfig;

Json buildContextData(const AgentModeConfig& cfg, RobotStruct& robot);
}
}
