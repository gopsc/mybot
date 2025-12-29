#pragma once
class ILearnable {
public:
    virtual void update(float discount) = 0;
};